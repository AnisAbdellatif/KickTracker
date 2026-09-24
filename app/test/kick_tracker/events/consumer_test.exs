defmodule KickTracker.Events.ConsumerTest do
  @moduledoc """
  The consumer's promises (project.md §8.2, §10): every good envelope
  stored once, acknowledged after the commit; anything that can't be
  decoded or verified dead-lettered, never retried in a loop; stream
  events handed to their channel only once stored.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  alias KickTracker.Events.{Consumer, WebhookEvent}
  alias KickTracker.Kick.PublicKey
  alias KickTracker.TestKick

  @follow ~s({"broadcaster":{"user_id":7},"follower":{"user_id":8}})
  @status ~s({"broadcaster":{"user_id":7},"is_live":true,"title":"t","started_at":"2026-09-24T18:00:00Z","ended_at":null})

  setup do
    test = self()
    start_supervised!({PublicKey, pem: TestKick.pem(), name: :consumer_test_key})

    start_supervised!(
      {Consumer,
       name: :consumer_test,
       producer: {Broadway.DummyProducer, []},
       public_key: :consumer_test_key,
       dispatch: fn envelopes ->
         send(test, {:dispatched, Enum.map(envelopes, & &1.message_id)})
       end}
    )

    :ok
  end

  defp stored, do: Repo.all(from e in WebhookEvent, order_by: e.message_id)

  test "a good envelope is stored, then acknowledged, then handed on" do
    message = TestKick.message("livestream.status.updated", @status, message_id: "01A")
    ref = Broadway.test_message(:consumer_test, message)

    assert_receive {:ack, ^ref, [_], []}, 2_000
    assert_received {:dispatched, ["01A"]}

    assert [%WebhookEvent{} = e] = stored()
    assert e.body == @status
    assert e.sent_at == "2026-09-24T18:02:11Z"
    assert e.receiver == "test/1"
    # Stream state waits for the channel's process.
    assert e.processed_at == nil
  end

  test "events that need no channel state are marked processed at once" do
    ref = Broadway.test_message(:consumer_test, TestKick.message("moderation.banned", "{}"))
    assert_receive {:ack, ^ref, [_], []}, 2_000
    assert [%{processed_at: %DateTime{}}] = stored()
  end

  test "a repeat is acknowledged but stored and handed on only once" do
    message = TestKick.message("channel.followed", @follow, message_id: "01B")

    ref = Broadway.test_batch(:consumer_test, [message, message])
    assert_receive {:ack, ^ref, [_, _], []}, 2_000
    ref = Broadway.test_message(:consumer_test, message)
    assert_receive {:ack, ^ref, [_], []}, 2_000

    assert [%{message_id: "01B"}] = stored()
    assert_received {:dispatched, ["01B"]}
    assert_received {:dispatched, []}
  end

  test "a bad signature or an undecodable message is dead-lettered, not requeued" do
    for data <- [
          TestKick.message("channel.followed", @follow, key: :other),
          TestKick.message("channel.followed", @follow, signature: "bm90IGEgc2lnbmF0dXJl"),
          "not an envelope",
          TestKick.envelope("channel.followed", @follow)
          |> Map.put("envelope_version", 9)
          |> Jason.encode!()
        ] do
      ref = Broadway.test_message(:consumer_test, data)
      assert_receive {:configure, ^ref, [on_failure: :reject]}, 2_000
      assert_receive {:ack, ^ref, [], [_]}, 2_000
    end

    assert stored() == []
  end

  test "one message that breaks the transaction is dead-lettered alone" do
    good = TestKick.message("channel.followed", @follow, message_id: "01C")
    # Postgres text can't hold a NUL: this one fails inside the transaction.
    bad = TestKick.message("channel.followed", @follow, message_id: "01D\u0000")
    also_good = TestKick.message("channel.followed", @follow, message_id: "01E")

    ref = Broadway.test_batch(:consumer_test, [good, bad, also_good])
    assert_receive {:configure, ^ref, [on_failure: :reject]}, 2_000
    assert_receive {:ack, ^ref, [_, _], [failed]}, 2_000

    assert {:store_failed, _} = failed.status |> elem(1)
    assert Enum.map(stored(), & &1.message_id) == ["01C", "01E"]
  end
end

defmodule KickTracker.Events.ConsumerRabbitTest do
  @moduledoc "The consumer against the real broker (the `test` vhost), as the app user."

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  alias KickTracker.Events.{Consumer, WebhookEvent}
  alias KickTracker.Kick.PublicKey
  alias KickTracker.{TestBroker, TestKick}

  setup do
    TestBroker.purge()
    Application.put_env(:kick_tracker, :amqp_url, TestBroker.app_url())
    on_exit(fn -> Application.delete_env(:kick_tracker, :amqp_url) end)

    start_supervised!({PublicKey, pem: TestKick.pem(), name: :rabbit_test_key})

    start_supervised!(
      {Consumer, name: :rabbit_test, public_key: :rabbit_test_key, dispatch: fn _ -> :ok end}
    )

    :ok
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() || tries == 0, do: fun.(), else: Process.sleep(50) && eventually(fun, tries - 1)
  end

  test "stored and acknowledged; a forged one ends in the dead-letter queue" do
    TestBroker.publish(TestKick.message("channel.followed", "{}", message_id: "01RABBIT"))
    TestBroker.publish(TestKick.message("channel.followed", "{}", key: :other))

    assert eventually(fn -> Repo.aggregate(WebhookEvent, :count) == 1 end)
    assert eventually(fn -> TestBroker.depth("kick_tracker.events.dead") == 1 end)
    assert eventually(fn -> TestBroker.depth("kick_tracker.events") == 0 end)
    assert Repo.get(WebhookEvent, "01RABBIT")
  end
end
