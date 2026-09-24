defmodule KickTracker.Tracking.PipelineSimTest do
  @moduledoc """
  Collection against the fake Kick: adding channels, polling, sessions,
  subscriber totals, token expiry, webhook subscriptions, and a Kick that
  doesn't answer.
  """

  use KickTracker.SimCase
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.{Channels, Stats}
  alias KickTracker.Kick.API
  alias KickTracker.Tracking.{ChannelServer, Manager, Poller}
  alias KickTracker.Workers.SubscriptionSync

  setup do
    start_sim([
      [slug: "livestreamer", schedule: :always, peak_viewers: 500],
      [slug: "offlinestreamer", schedule: :never]
    ])

    start_collector()
    {:ok, live} = Channels.add("livestreamer")
    {:ok, off} = Channels.add("offlinestreamer")
    Manager.sync()
    %{live: live, off: off}
  end

  test "an unknown slug can't be added", _ do
    assert Channels.add("nosuchstreamer") == {:error, :not_found}
  end

  test "a poll opens the live channel's stream, with Kick's own start, and samples it",
       %{live: live, off: off} do
    Poller.poll_now(channels: true)
    %{open_stream: started_at} = ChannelServer.info(live.kick_user_id)

    kick_start =
      Sim.Server.scenario()
      |> Sim.Scenario.channel("livestreamer")
      |> Sim.Schedule.stream_at(Sim.Server.now())
      |> Map.fetch!(:started_at)

    assert DateTime.compare(started_at, kick_start) == :eq
    assert %{open_stream: nil, streams: []} = ChannelServer.info(off.kick_user_id)

    assert [%{channel_id: id, viewers: v}] = rows("viewer_samples", ["observed_at"])
    assert id == live.id and v > 0

    # Subscriber totals for both, live or not; coverage for both.
    assert rows("subscriber_samples", ["channel_id"]) |> Enum.map(& &1.channel_id) |> Enum.sort() ==
             Enum.sort([live.id, off.id])

    assert rows("coverage", ["id"]) |> Enum.map(&{&1.source, &1.ok}) |> Enum.frequencies() ==
             %{{"api", true} => 2, {"subscribers", true} => 2}

    # The poll's title and category are the stream's first values.
    assert {%{"title" => title, "category" => _}, _} =
             Stats.current_values(Stats.stream_id!(live.id, started_at))

    assert is_binary(title)
  end

  test "an expired token is replaced without losing the poll", %{live: live} do
    Poller.poll_now()
    Sim.Server.expire_tokens()
    Poller.poll_now()

    assert length(rows("viewer_samples", ["observed_at"])) == 2
    assert [%{channel_id: id}] = rows("streams", ["id"])
    assert id == live.id
  end

  test "Kick not answering is a recorded gap, never zero or offline", %{live: live} do
    Poller.poll_now()
    config = Application.get_env(:kick_tracker, :kick)
    Application.put_env(:kick_tracker, :kick, Keyword.put(config, :api_url, "http://127.0.0.1:1"))
    Poller.poll_now()
    Application.put_env(:kick_tracker, :kick, config)

    assert [%{viewers: _}] = rows("viewer_samples", ["observed_at"])
    assert %{open_stream: %DateTime{}} = ChannelServer.info(live.kick_user_id)

    assert rows("coverage", ["id"])
           |> Enum.filter(&(&1.channel_id == live.id))
           |> Enum.map(& &1.ok) == [true, false]
  end

  test "webhook subscriptions follow the tracked set, and come back if Kick drops them",
       %{off: off} do
    :ok = SubscriptionSync.perform(%Oban.Job{})
    {:ok, subs} = API.subscriptions()
    assert length(subs) == 2 * length(SubscriptionSync.events())

    # Kick cancels one; the next sync restores it.
    :ok = API.unsubscribe([hd(subs)["id"]])
    :ok = SubscriptionSync.perform(%Oban.Job{})
    {:ok, subs} = API.subscriptions()
    assert length(subs) == 2 * length(SubscriptionSync.events())

    # A channel no longer tracked loses its subscriptions and its process.
    {:ok, _} = Channels.set_active(off, false)
    Manager.sync()
    :ok = SubscriptionSync.perform(%Oban.Job{})
    {:ok, subs} = API.subscriptions()
    assert Enum.all?(subs, &(&1["broadcaster_user_id"] != off.kick_user_id))
    assert length(subs) == length(SubscriptionSync.events())
    assert eventually(fn -> ChannelServer.whereis(off.kick_user_id) == nil end)
  end
end
