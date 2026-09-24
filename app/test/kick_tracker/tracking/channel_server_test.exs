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
end
