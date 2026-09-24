defmodule KickTracker.Workers.ProcessEventsTest do
  use KickTracker.DataCase, async: false
  use Oban.Testing, repo: KickTracker.Repo

  import KickTracker.Fixtures
  alias KickTracker.{Events, TestKick}
  alias KickTracker.Events.{Envelope, WebhookEvent}
  alias KickTracker.Workers.ProcessEvents

  setup do
    start_supervised!({Registry, keys: :unique, name: KickTracker.Tracking.registry()})
    :ok
  end

  # Stream status events for this broadcaster, stored `ago` seconds ago.
  defp stored_statuses!(kick_user_id, ago, count) do
    body = %{
      "broadcaster" => TestKick.user(kick_user_id),
      "is_live" => true,
      "title" => "t",
      "started_at" => "2026-09-24T18:00:00Z",
      "ended_at" => nil
    }

    envelopes =
      for _ <- 1..count do
        {:ok, e} = TestKick.message("livestream.status.updated", body) |> Envelope.decode()
        e
      end

    {:ok, _} = Events.ingest(envelopes)
    ids = Enum.map(envelopes, & &1.message_id)
    at = DateTime.add(DateTime.utc_now(), -ago)
    Repo.update_all(from(w in WebhookEvent, where: w.message_id in ^ids), set: [stored_at: at])
    ids
  end

  defp stored_status!(kick_user_id, ago),
    do: kick_user_id |> stored_statuses!(ago, 1) |> hd()

  defp processed?(message_id), do: Repo.get!(WebhookEvent, message_id).processed_at != nil

  test "a stopped channel with more than a page of events doesn't starve the others" do
    stopped = channel!()
    gone = channel!(active: false)

    # Oldest first: the stopped channel's events fill the whole first page.
    held = stored_statuses!(stopped.kick_user_id, 1_000, 501)
    untracked = stored_status!(gone.kick_user_id, 600)
    unknown = stored_status!(424_242, 500)

    assert :ok = perform_job(ProcessEvents, %{})

    # Before the fix only the 500 oldest were read: the other channels'
    # events stayed unprocessed for as long as the stopped one's did.
    assert processed?(untracked)
    assert processed?(unknown)
    refute Enum.any?(held, &processed?/1)
  end

  test "small pages reach everything too" do
    stopped = channel!()
    held = for i <- 1..5, do: stored_status!(stopped.kick_user_id, 1_000 - i)
    unknown = stored_status!(424_242, 500)

    assert :ok = perform_job(ProcessEvents, %{"page_size" => 2})

    assert processed?(unknown)
    refute Enum.any?(held, &processed?/1)
  end

  test "a running channel's events are handed to it, page after page" do
    running = channel!()
    Registry.register(KickTracker.Tracking.registry(), {:channel, running.kick_user_id}, nil)

    ids = for i <- 1..5, do: stored_status!(running.kick_user_id, 1_000 - i)
    recent = stored_status!(running.kick_user_id, 10)

    assert :ok = perform_job(ProcessEvents, %{"page_size" => 2})

    handed =
      for _ <- ids do
        assert_receive {:event, %Envelope{message_id: id}}
        id
      end

    assert Enum.sort(handed) == Enum.sort(ids)
    # Stored too recently to be retried yet.
    refute_received {:event, %Envelope{message_id: ^recent}}
  end

  describe "unprocessed_for/1" do
    test "only that broadcaster's, including ones stored before the column existed" do
      c = channel!()
      mine = stored_status!(c.kick_user_id, 100)
      _theirs = stored_status!(c.kick_user_id + 1, 90)
      legacy = stored_status!(c.kick_user_id, 80)
      legacy_theirs = stored_status!(c.kick_user_id + 1, 70)

      Repo.update_all(
        from(w in WebhookEvent, where: w.message_id in ^[legacy, legacy_theirs]),
        set: [broadcaster_user_id: nil]
      )

      assert Enum.map(Events.unprocessed_for(c.kick_user_id), & &1.message_id) == [mine, legacy]
    end
  end
end
