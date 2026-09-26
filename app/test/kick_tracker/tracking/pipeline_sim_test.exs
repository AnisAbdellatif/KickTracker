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
  alias KickTracker.Tracking.{ChannelServer, Manager}
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

  test "each poll sends one aggregated live broadcast with the live channels' viewers",
       %{live: live, off: off} do
    Phoenix.PubSub.subscribe(KickTracker.PubSub, KickTracker.Tracking.live_topic())
    poll()
    assert_receive {:live, %{viewers: viewers}}
    assert is_integer(viewers[live.id])
    refute Map.has_key?(viewers, off.id)
  end

  test "an unknown slug can't be added", _ do
    assert Channels.add("nosuchstreamer") == {:error, :not_found}
  end

  test "a poll opens the live channel's stream, with Kick's own start, and samples it",
       %{live: live, off: off} do
    poll(channels: true)
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
    poll()
    Sim.Server.expire_tokens()
    poll()

    assert length(rows("viewer_samples", ["observed_at"])) == 2
    assert [%{channel_id: id}] = rows("streams", ["id"])
    assert id == live.id
  end

  test "Kick not answering is a recorded gap, never zero or offline", %{live: live} do
    poll()
    config = Application.get_env(:kick_tracker, :kick)
    Application.put_env(:kick_tracker, :kick, Keyword.put(config, :api_url, "http://127.0.0.1:1"))
    poll()
    Application.put_env(:kick_tracker, :kick, config)

    assert [%{viewers: _}] = rows("viewer_samples", ["observed_at"])
    assert %{open_stream: %DateTime{}} = ChannelServer.info(live.kick_user_id)

    assert rows("coverage", ["id"])
           |> Enum.filter(&(&1.channel_id == live.id and &1.source == "api"))
           |> Enum.map(& &1.ok) == [true, false]
  end

  test "a reading no channel process was there to write is a gap, not coverage", %{live: live} do
    # The channel's processes are down (restarting, quarantined) during a
    # poll that worked. Before, the whole batch was recorded as covered.
    sup = KickTracker.Tracking.whereis({:channel_sup, live.id})
    DynamicSupervisor.terminate_child(KickTracker.Tracking.ChannelsSupervisor, sup)
    poll()

    assert rows("viewer_samples", ["observed_at"]) == []
    assert Enum.filter(rows("coverage", ["id"]), &(&1.channel_id == live.id)) == []
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

  test "a sync removes more subscriptions than one request takes", %{live: live, off: off} do
    # What a fresh instance on an app with a previous instance's
    # subscriptions sees: hundreds to remove at once.
    for user_id <- 1..20, do: {:ok, _} = API.subscribe(user_id, SubscriptionSync.events())
    {:ok, subs} = API.subscriptions()
    assert length(subs) > 100

    :ok = SubscriptionSync.perform(%Oban.Job{})
    {:ok, subs} = API.subscriptions()

    assert length(subs) == 2 * length(SubscriptionSync.events())

    assert subs |> Enum.map(& &1["broadcaster_user_id"]) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort([live.kick_user_id, off.kick_user_id])
  end
end

defmodule KickTracker.Tracking.FollowersSimTest do
  @moduledoc "Follower readings from the fake Kick's v2, by the followers source."

  use KickTracker.SimCase
  @moduletag :capture_log
  use Oban.Testing, repo: KickTracker.Repo

  import KickTracker.Fixtures
  alias KickTracker.Channels
  alias KickTracker.Collector.Sources.Followers
  alias KickTracker.Workers.FollowerPoll

  setup do
    start_sim([
      [slug: "livestreamer", schedule: :always],
      [slug: "offlinestreamer", schedule: :never]
    ])

    start_collector()
    :ok
  end

  test "adding a channel asks for a reading, which stores the total and learns the chatroom" do
    {:ok, c} = Channels.add("livestreamer")
    assert_enqueued(worker: FollowerPoll, args: %{channel_id: c.id, reason: "added"})

    # The job, run where collection runs, hands the request to the source.
    :ok = perform_job(FollowerPoll, %{channel_id: c.id, reason: "added"})
    run_source(Followers)

    sim = Sim.Scenario.channel(Sim.Server.scenario(), "livestreamer")
    assert [%{followers: n}] = rows("follower_samples", ["observed_at"])
    assert n == Sim.Curve.followers(sim, Sim.Server.now()) or n > 0
    assert Channels.get!(c.id).chatroom_id == sim.chatroom_id
    # (Learning the chatroom starts the chat, which has coverage of its own.)
    assert [%{ok: true}] = rows("coverage", ["id"]) |> Enum.filter(&(&1.source == "followers"))
  end

  test "v2 failing is a gap, not a zero, and isn't retried at every cycle" do
    {:ok, c} = Channels.add("livestreamer")
    config = Application.get_env(:kick_tracker, :kick)
    Application.put_env(:kick_tracker, :kick, Keyword.put(config, :v2_url, "http://127.0.0.1:1"))
    Followers.request(c.id, :test)
    run_source(Followers)
    run_source(Followers)
    Application.put_env(:kick_tracker, :kick, config)

    assert rows("follower_samples", ["observed_at"]) == []
    assert [%{source: "followers", ok: false}] = rows("coverage", ["id"])
  end

  test "the schedule: live channels every 15 minutes, offline ones daily" do
    {:ok, live} = Channels.add("livestreamer")
    {:ok, off} = Channels.add("offlinestreamer")
    now = DateTime.utc_now()

    for {c, ago} <- [{live, 20 * 60}, {off, 3 * 3600}] do
      KickTracker.Stats.insert_samples("follower_samples", [
        %{channel_id: c.id, observed_at: DateTime.add(now, -ago), followers: 1}
      ])
    end

    KickTracker.Tracking.Manager.sync()
    poll()
    run_source(Followers)

    count = fn c ->
      Enum.count(rows("follower_samples", ["observed_at"]), &(&1.channel_id == c.id))
    end

    assert count.(live) == 2
    assert count.(off) == 1
  end
end

defmodule KickTracker.Tracking.ChatSimTest do
  @moduledoc "Chat from the fake Kick's Pusher, through the socket, into the chat tables."

  use KickTracker.SimCase
  @moduletag :capture_log

  import KickTracker.Fixtures
  alias KickTracker.Channels
  alias KickTracker.Tracking.{ChannelServer, ChatSocket, Manager}

  setup do
    start_sim([[slug: "livestreamer", schedule: :always]])
    start_collector()
    {:ok, c} = Channels.add("livestreamer")
    sim = Sim.Scenario.channel(Sim.Server.scenario(), "livestreamer")
    Manager.sync()
    # The chatroom id arrives after the channel's processes started (in
    # production, from the first follower reading): the socket connects then.
    c = Channels.put_ids(c, nil, sim.chatroom_id)
    Channels.announce(c)
    poll()
    socket = KickTracker.Tracking.whereis({:chat, c.id})
    assert eventually(fn -> ChatSocket.subscribed?(socket) end)
    %{channel: c, socket: socket}
  end

  defp say(sender, text \\ "hello"),
    do: sim_ctl(:post, "/channels/livestreamer/chat", %{"content" => text, "sender_id" => sender})

  defp flush(c) do
    pid = ChannelServer.whereis(c.kick_user_id)
    ChannelServer.flush_chat_now(pid, DateTime.add(DateTime.utc_now(), 600))
  end

  # The fake Kick's own audience chats too; these senders are the test's.
  @a 990_000_101
  @b 990_000_102

  defp mine(table, key),
    do: rows(table, [key]) |> Enum.filter(&(&1.user_id in [@a, @b]))

  test "messages become per-minute counts inside the open stream, and no text is stored",
       %{channel: c} do
    say(@a, "a secret message")
    say(@a, "second")
    say(@b, "third")

    assert eventually(fn ->
             flush(c)
             Enum.sum_by(mine("chat_minute_users", "user_id"), & &1.messages) == 3
           end)

    [stream] = rows("streams", ["id"])
    assert Enum.all?(rows("chat_minutes", ["minute"]), &(&1.stream_id == stream.id))

    assert mine("chat_stream_users", "user_id") |> Enum.map(&{&1.user_id, &1.messages}) ==
             [{@a, 2}, {@b, 1}]

    assert Enum.all?(
             [@a, @b],
             &(Repo.query!("SELECT 1 FROM kick_users WHERE id = $1", [&1]).num_rows == 1)
           )

    %{rows: dump} =
      Repo.query!("SELECT * FROM chat_minutes, chat_minute_users, chat_stream_users, kick_users")

    refute inspect(dump) =~ "secret"
  end

  test "a host is stored as sent; other unknown events are not", %{channel: c} do
    topic = "chatrooms.#{c.chatroom_id}.v2"

    frame = fn name ->
      Jason.encode!(%{"event" => name, "channel" => topic, "data" => ~s({"opaque":"a host"})})
    end

    Sim.Pusher.Hub.broadcast(topic, [
      frame.("App\\Events\\StreamHostEvent"),
      frame.("App\\Events\\SomethingElse")
    ])

    assert eventually(fn -> rows("channel_events", ["id"]) != [] end)
    settle()

    assert [%{channel_id: id, kind: "hosted_by", viewers: nil, payload: payload}] =
             rows("channel_events", ["id"])

    assert id == c.id

    assert payload == %{
             "event" => "App\\Events\\StreamHostEvent",
             "pusher_channel" => topic,
             "data" => %{"opaque" => "a host"}
           }
  end

  test "a dropped connection is a recorded gap, then chat resumes", %{channel: c, socket: socket} do
    sim_ctl(:post, "/pusher/disconnect")
    assert eventually(fn -> not ChatSocket.subscribed?(socket) end)
    assert eventually(fn -> ChatSocket.subscribed?(socket) end)

    say(103)

    assert eventually(fn ->
             flush(c)
             rows("chat_minutes", ["minute"]) != []
           end)

    chat = rows("coverage", ["id"]) |> Enum.filter(&(&1.source == "chat")) |> Enum.map(& &1.ok)
    assert chat == [true, false, true]
  end

  test "a connection dropped soon after it came up doesn't start the backoff over",
       %{socket: socket} do
    # Before, every successful subscription reset the backoff to 1s, so a
    # server that accepted and then dropped was retried every second or two.
    for expected <- [2_000, 4_000] do
      sim_ctl(:post, "/pusher/disconnect")
      assert eventually(fn -> not ChatSocket.subscribed?(socket) end)
      assert eventually(fn -> ChatSocket.subscribed?(socket) end, 200)
      assert :sys.get_state(socket).backoff_ms == expected
    end

    for _ <- 1..50 do
      delay = ChatSocket.jitter(8_000)
      assert delay >= 6_000 and delay <= 8_000
    end
  end

  test "when the channel's process restarts, the socket restarts knowing the chatroom", %{
    channel: c,
    socket: socket
  } do
    # The channel's supervisor was started before the chatroom id was
    # known; before, the restarted socket got that first row (no chatroom)
    # and never connected again.
    Process.exit(ChannelServer.whereis(c.kick_user_id), :kill)

    new_socket =
      eventually(fn ->
        pid = KickTracker.Tracking.whereis({:chat, c.id})
        pid != socket and pid != nil and pid
      end)

    assert new_socket
    assert eventually(fn -> ChatSocket.subscribed?(new_socket) end, 200)
    assert :sys.get_state(new_socket).channel.chatroom_id == c.chatroom_id
  end

  test "a chatroom id that changes moves the socket to the new chatroom", %{
    channel: c,
    socket: socket
  } do
    Channels.announce(c.id, %{chatroom_id: c.chatroom_id + 1})

    assert eventually(fn -> :sys.get_state(socket).channel.chatroom_id == c.chatroom_id + 1 end)
    assert eventually(fn -> ChatSocket.subscribed?(socket) end, 200)

    chat = rows("coverage", ["id"]) |> Enum.filter(&(&1.source == "chat")) |> Enum.map(& &1.ok)
    assert chat == [true, false, true]
  end
end
