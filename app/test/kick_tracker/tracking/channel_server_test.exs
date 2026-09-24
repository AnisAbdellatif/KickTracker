defmodule KickTracker.Tracking.ChannelServerTest do
  @moduledoc """
  The channel process: readings and events in, streams, samples and
  changes out, whatever order the events arrive in.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.{Events, TestKick}
  alias KickTracker.Events.Envelope
  alias KickTracker.Tracking.ChannelServer

  @s ~U[2026-01-05 20:00:00Z]
  defp at(s), do: DateTime.add(@s, s) |> KickTracker.Metrics.Sessionizer.norm()
  defp iso(t), do: t |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  setup do
    start_supervised!({Registry, keys: :unique, name: KickTracker.Tracking.registry()})
    channel = channel!()
    %{channel: channel}
  end

  defp start(channel, id \\ :cs) do
    pid = start_supervised!(Supervisor.child_spec({ChannelServer, channel}, id: id))
    ChannelServer.info(pid)
    pid
  end

  defp broadcaster(c), do: TestKick.user(c.kick_user_id, c.slug)

  defp livestream(c, viewers, opts \\ []) do
    %{
      "broadcaster_user_id" => c.kick_user_id,
      "started_at" => iso(Keyword.get(opts, :started_at, @s)),
      "viewer_count" => viewers,
      "stream_title" => Keyword.get(opts, :title, "first title"),
      "category" => %{"id" => 15, "name" => "Just Chatting", "thumbnail" => ""},
      "language" => "en",
      "has_mature_content" => false
    }
  end

  # Stored like the consumer stores it, then returned for handing over.
  defp envelope(type, body, sent_at) do
    {:ok, e} = TestKick.message(type, body, sent_at: iso(sent_at)) |> Envelope.decode()
    {:ok, [e]} = Events.ingest([e])
    e
  end

  defp status(c, live?, ended_at \\ nil) do
    %{
      "broadcaster" => broadcaster(c),
      "is_live" => live?,
      "title" => "t",
      "started_at" => iso(@s),
      "ended_at" => ended_at && iso(ended_at)
    }
  end

  defp metadata(c, title, category_id \\ 15) do
    category = %{"id" => category_id, "name" => "Category #{category_id}", "thumbnail" => ""}

    %{
      "broadcaster" => broadcaster(c),
      "metadata" => %{
        "title" => title,
        "language" => "en",
        "has_mature_content" => false,
        "category" => category,
        "Category" => category
      }
    }
  end

  defp sync(pid), do: ChannelServer.info(pid)

  test "readings open the stream and become samples carrying the category", %{channel: c} do
    pid = start(c)
    for {s, v} <- [{30, 100}, {90, 120}], do: send(pid, {:reading, livestream(c, v), at(s)})
    sync(pid)

    assert [%{started_at: started, ended_at: nil}] = rows("streams", ["id"])
    assert started == at(0)

    assert [%{viewers: 100, category_id: 15}, %{viewers: 120}] =
             rows("viewer_samples", ["observed_at"])

    assert [%{id: 15, name: "Just Chatting"}] = rows("categories", ["id"])
  end

  test "the end event closes the stream; a lagging poll after it adds nothing", %{channel: c} do
    pid = start(c)
    send(pid, {:event, envelope("livestream.status.updated", status(c, true), at(1))})
    send(pid, {:reading, livestream(c, 50), at(30)})
    send(pid, {:event, envelope("livestream.status.updated", status(c, false, at(60)), at(62))})
    send(pid, {:reading, livestream(c, 40), at(70)})
    sync(pid)

    assert [%{ended_at: ended, end_source: "event"}] = rows("streams", ["id"])
    assert ended == at(60)
    assert [%{viewers: 50}] = rows("viewer_samples", ["observed_at"])
    assert Enum.all?(rows("webhook_events", ["message_id"]), & &1.processed_at)
  end

  test "an end event arriving before the start gives the same stream", %{channel: c} do
    pid = start(c)
    send(pid, {:event, envelope("livestream.status.updated", status(c, false, at(600)), at(601))})
    send(pid, {:event, envelope("livestream.status.updated", status(c, true), at(1))})
    sync(pid)

    assert [%{ended_at: ended, end_source: "event"}] = rows("streams", ["id"])
    assert ended == at(600)
  end

  test "metadata becomes a change log; a snapshot arriving before the start isn't lost", %{
    channel: c
  } do
    pid = start(c)
    send(pid, {:event, envelope("livestream.metadata.updated", metadata(c, "hello"), at(2))})
    send(pid, {:event, envelope("livestream.status.updated", status(c, true), at(1))})

    send(
      pid,
      {:event, envelope("livestream.metadata.updated", metadata(c, "hello", 42), at(600))}
    )

    sync(pid)

    changes =
      for r <- rows("stream_changes", ["occurred_at", "field"]),
          do: {DateTime.diff(r.occurred_at, at(0)), r.field, r.old_value, r.new_value}

    assert changes == [
             {2, "category", nil, "15"},
             {2, "language", nil, "en"},
             {2, "mature", nil, "false"},
             {2, "title", nil, "hello"},
             {600, "category", "15", "42"}
           ]
  end

  test "a restart mid-stream reloads the open stream and handles events stored meanwhile", %{
    channel: c
  } do
    pid = start(c)
    send(pid, {:reading, livestream(c, 100), at(30)})
    sync(pid)
    stop_supervised!(:cs)

    # While it was down, the end event was stored but not handed over.
    envelope("livestream.status.updated", status(c, false, at(300)), at(301))

    pid = start(c)
    assert %{open_stream: nil, streams: [{_, ended, :event}]} = ChannelServer.info(pid)
    assert ended == at(300)
    assert [%{end_source: "event"}] = rows("streams", ["id"])
  end

  test "an event that can't be handled is skipped and marked, and the channel carries on", %{
    channel: c
  } do
    pid = start(c)
    e = envelope("livestream.status.updated", status(c, true), at(0))
    # A body that parses but isn't the object the handler expects.
    send(pid, {:event, %{e | body: "[1, 2]"}})
    sync(pid)

    assert Process.alive?(pid)
    assert [%{processed_at: %DateTime{}}] = rows("webhook_events", ["message_id"])

    send(pid, {:reading, livestream(c, 100), at(30)})
    assert %{open_stream: %DateTime{}} = sync(pid)
  end

  test "restarted within the same lease term, it starts from its snapshot, not the database", %{
    channel: c
  } do
    start_supervised!(KickTracker.Collector.Journal)
    KickTracker.Collector.put_leadership(true, 9)
    on_exit(fn -> :persistent_term.erase({KickTracker.Collector, :epoch}) end)

    pid = start(c)
    send(pid, {:reading, livestream(c, 100), at(30)})
    sync(pid)
    stop_supervised!(:cs)

    # As if its writes were still in the journal, not yet in Postgres.
    Repo.query!("DELETE FROM viewer_samples")
    Repo.query!("DELETE FROM stream_changes")
    Repo.query!("DELETE FROM streams")

    pid = start(c)
    assert %{open_stream: started_at} = ChannelServer.info(pid)
    assert started_at == at(0)
  end

  defp changes do
    for r <- rows("stream_changes", ["occurred_at", "field"]),
        do: {DateTime.diff(r.occurred_at, @s), r.field, r.old_value, r.new_value, r.source}
  end

  test "metadata held with no stream open goes to the next stream only if it came just before it",
       %{channel: c} do
    # The same input twice, differing only in the held event's age. Before,
    # both went to the stream as its first values, labelled `event`: a
    # three-day-old title became the stream's, and the poll then recorded a
    # change back. Now only one from just before the start is applied.
    stale = channel!()
    pid = start(stale, :stale)
    old = envelope("livestream.metadata.updated", metadata(stale, "old title"), at(-3 * 86_400))
    send(pid, {:event, old})
    send(pid, {:event, envelope("livestream.status.updated", status(stale, true), at(1))})
    send(pid, {:reading, livestream(stale, 100), at(30)})
    sync(pid)

    # Nothing from the stale event: the stream's first values are the poll's.
    assert Enum.all?(changes(), fn {_, _, _, value, source} ->
             value != "old title" and source == "poll"
           end)

    assert {30, "title", nil, "first title", "poll"} in changes()

    Repo.query!("DELETE FROM stream_changes")
    pid = start(c)
    held_at = at(-ChannelServer.held_meta_window_s() + 60)
    send(pid, {:event, envelope("livestream.metadata.updated", metadata(c, "hello"), held_at)})
    send(pid, {:event, envelope("livestream.status.updated", status(c, true), at(1))})
    sync(pid)

    # Dated at the stream's start, which it came just before.
    assert {0, "title", nil, "hello", "event"} in changes()
  end

  test "a stream closed from polling that reopens continues its change log", %{channel: c} do
    pid = start(c)
    send(pid, {:reading, livestream(c, 100), at(30)})
    # Missed for more than 90s: closed from polling.
    send(pid, {:reading, :offline, at(200)})
    assert %{open_stream: nil} = sync(pid)

    # Seen live again: reopens. The new title is seen once, then twice.
    send(pid, {:reading, livestream(c, 90, title: "second title"), at(260)})
    sync(pid)
    # Before, the reopened stream started an empty log: this one sighting
    # was recorded at once as a "first value" (no old value), against the
    # rule that a poll needs two sightings.
    refute Enum.any?(changes(), &match?({_, "title", _, "second title", _}, &1))

    send(pid, {:reading, livestream(c, 90, title: "second title"), at(320)})
    sync(pid)
    assert {260, "title", "first title", "second title", "poll"} in changes()
    assert [%{ended_at: nil}] = rows("streams", ["id"])
  end

  test "a stream reopened after a restart continues its log from the database", %{channel: c} do
    pid = start(c)
    send(pid, {:reading, livestream(c, 100), at(30)})
    send(pid, {:reading, :offline, at(200)})
    sync(pid)
    stop_supervised!(:cs)

    pid = start(c)
    send(pid, {:reading, livestream(c, 90, title: "second title"), at(260)})
    sync(pid)
    refute Enum.any?(changes(), &match?({_, "title", _, "second title", _}, &1))
    send(pid, {:reading, livestream(c, 90, title: "second title"), at(320)})
    sync(pid)
    assert {260, "title", "first title", "second title", "poll"} in changes()
  end

  test "each reading handled records the viewers poll's coverage for the channel", %{channel: c} do
    pid = start(c)
    send(pid, {:reading, livestream(c, 100), at(30)})
    send(pid, {:reading, :offline, at(90)})
    sync(pid)

    assert [%{source: "api", ok: true, from_at: from, to_at: to}] = rows("coverage", ["id"])
    assert {from, to} == {at(30), at(90)}
  end

  test "chat written before the stream was known becomes the stream's when it opens", %{
    channel: c
  } do
    pid = start(c)

    chat = fn sender, t ->
      send(pid, {:chat, %{id: "m#{sender}-#{t}", sender_id: sender, username: nil, at: at(t)}})
    end

    # Offline chat before the start, then chat after Kick's start time but
    # before anything told this process the stream had started.
    chat.(11, -120)
    chat.(11, 30)
    chat.(12, 95)
    chat.(12, 100)
    sync(pid)
    ChannelServer.flush_chat_now(pid, at(600))
    assert Enum.all?(rows("chat_minutes", ["minute"]), &(&1.stream_id == nil))

    # The poll that finally shows the stream (its start: at(0)).
    send(pid, {:reading, livestream(c, 100), at(240)})
    sync(pid)

    [stream] = rows("streams", ["id"])

    minutes =
      rows("chat_minutes", ["minute"]) |> Enum.map(&{DateTime.diff(&1.minute, @s), &1.stream_id})

    # The offline minute stays offline.
    assert minutes == [{-120, nil}, {0, stream.id}, {60, stream.id}]

    per_stream = fn ->
      rows("chat_stream_users", ["user_id"]) |> Enum.map(&{&1.user_id, &1.messages})
    end

    assert per_stream.() == [{11, 1}, {12, 2}]

    # Replayed, it changes nothing.
    KickTracker.Stats.attribute_chat(c.id, stream.id, DateTime.utc_now())
    assert per_stream.() == [{11, 1}, {12, 2}]
  end

  test "an event that stopped the channel at every start is set aside after a few tries", %{
    channel: c
  } do
    alias KickTracker.Collector.Journal
    start_supervised!(Journal)
    poison = envelope("livestream.status.updated", status(c, true), at(0))
    # As if three starts in a row had died handling it.
    Journal.put({:catch_up_attempts, c.id}, %{poison.message_id => 3})

    pid = start(c)
    # Not handled (no stream), but marked, so the next start doesn't try it again.
    assert %{open_stream: nil} = ChannelServer.info(pid)
    assert [%{processed_at: %DateTime{}}] = rows("webhook_events", ["message_id"])

    # An event tried fewer times is handled as usual.
    stop_supervised!(:cs)
    other = envelope("livestream.status.updated", status(c, true), at(5))
    Journal.put({:catch_up_attempts, c.id}, %{other.message_id => 1})
    pid = start(c)
    assert %{open_stream: %DateTime{}} = ChannelServer.info(pid)
    assert Journal.get({:catch_up_attempts, c.id}) == %{}
  end

  test "a restarted process starts from the channel's row as it is now", %{channel: c} do
    pid = start(c)
    assert %{channel: %{chatroom_id: nil}} = ChannelServer.info(pid)
    stop_supervised!(:cs)

    KickTracker.Channels.store_ids(c.id, nil, 424_242)
    # Given the same (older) row the supervisor was given at first.
    pid = start(c)
    assert %{channel: %{chatroom_id: 424_242}} = ChannelServer.info(pid)

    # A field announced later is merged; the rest of the row is kept.
    KickTracker.Channels.announce(c.id, %{kick_channel_id: 77})
    assert %{channel: %{chatroom_id: 424_242, kick_channel_id: 77}} = ChannelServer.info(pid)
  end
end
