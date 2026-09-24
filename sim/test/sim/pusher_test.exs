defmodule Sim.PusherTest do
  @moduledoc """
  The fake Pusher, driven by the recorder's own Pusher client (the code
  that recorded the real one), so a protocol mismatch shows up as a failure
  here rather than in the app later.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Sim.Channel.Server, as: ChannelServer
  alias Sim.Pusher.{Hub, Socket}
  alias Sim.Recorder.Pusher, as: Client
  alias Sim.{Clock, Fixtures, Instance, Scenario, Server}

  @slug "somestreamer"
  # Twenty minutes into a Monday evening stream.
  @live ~U[2026-01-05 20:20:00Z]

  defp start(extra \\ []) do
    scenario =
      Scenario.new(
        channels: [
          [
            slug: @slug,
            peak_viewers: 3_000,
            schedule: %{days: [1], start_hour: 20, duration_min: 180}
          ]
        ],
        faults: Keyword.get(extra, :faults, [])
      )

    start_supervised!(
      {Instance,
       [
         scenario: scenario,
         clock: Keyword.get(extra, :clock, Clock.new(sim_start: @live)),
         port: 0,
         tick_ms: 0
       ] ++
         Keyword.take(extra, [:pusher])}
    )

    Scenario.channel(scenario, @slug)
  end

  # Runs the recorder's client for `ms`, stepping the channel meanwhile.
  defp record(dir, channels, ms, url \\ nil, steps \\ []) do
    task =
      Task.async(fn ->
        Client.record(url || Instance.pusher_url(),
          run: dir,
          name: "sim",
          channels: channels,
          deadline_ms: System.monotonic_time(:millisecond) + ms
        )
      end)

    Enum.each(steps, fn step ->
      Process.sleep(step.after_ms)
      step.fun.()
    end)

    result = Task.await(task, ms + 5_000)

    lines =
      dir
      |> Path.join("pusher/sim.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    {result, lines}
  end

  defp frames(lines, direction) do
    for %{"direction" => ^direction, "frame" => frame} <- lines,
        is_binary(frame),
        do: Jason.decode!(frame)
  end

  defp events(frames), do: Enum.map(frames, & &1["event"])

  defp wait_for(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(20) && {:cont, false}
    end)
  end

  test "connects, subscribes, and receives a live stream's chat", %{tmp_dir: dir} do
    channel = start()
    topic = "chatrooms.#{channel.chatroom_id}.v2"

    steps = [
      %{after_ms: 300, fun: fn -> wait_for(fn -> Hub.listened?(topic) end) end},
      %{
        after_ms: 0,
        fun: fn ->
          Server.put_clock(Clock.new(sim_start: DateTime.add(@live, 60, :second)))
          ChannelServer.tick(@slug)
        end
      }
    ]

    {result, lines} = record(dir, [topic, "channel.#{channel.channel_id}"], 1_500, nil, steps)
    assert {:ok, _} = result

    incoming = frames(lines, "in")
    assert hd(events(incoming)) == "pusher:connection_established"
    assert Enum.count(events(incoming), &(&1 == "pusher_internal:subscription_succeeded")) == 2

    chat = Enum.filter(incoming, &(&1["event"] == "App\\Events\\ChatMessageEvent"))
    assert chat != [], "a minute of a 3 000-viewer stream should have chat"
    assert Enum.all?(chat, &(&1["channel"] == topic))

    # `data` is a JSON document inside a string, as Pusher sends it.
    data = Enum.map(chat, &Jason.decode!(&1["data"]))
    assert Enum.all?(data, &(&1["chatroom_id"] == channel.chatroom_id))
    assert Enum.all?(data, &(&1["created_at"] =~ ~r/\+00:00$/))
  end

  test "the handshake frames match the recorded ones", %{tmp_dir: dir} do
    start()
    {_result, lines} = record(dir, ["chatrooms.1.v2"], 400)

    ours = Map.new(frames(lines, "in"), &{&1["event"], &1})
    real = Map.new(Fixtures.pusher_frames(), &{&1["event"], &1})

    for event <- ["pusher:connection_established", "pusher_internal:subscription_succeeded"] do
      assert Map.keys(ours[event]) |> Enum.sort() == Map.keys(real[event]) |> Enum.sort()
      assert is_binary(ours[event]["data"]), "#{event}: data must be a JSON string"
    end

    established = Jason.decode!(ours["pusher:connection_established"]["data"])

    assert established["activity_timeout"] ==
             Jason.decode!(real["pusher:connection_established"]["data"])["activity_timeout"]

    assert is_binary(established["socket_id"])
  end

  test "the server pings, and a client that answers stays connected", %{tmp_dir: dir} do
    start(pusher: [ping_ms: 150])
    {result, lines} = record(dir, ["chatrooms.1.v2"], 700)

    assert {:ok, _} = result
    assert "pusher:ping" in events(frames(lines, "in"))
    assert "pusher:pong" in events(frames(lines, "out"))
    # Answering pings keeps it connected until the deadline, not a 4201.
    assert %{"frame" => %{"event" => "deadline"}} = List.last(lines)
  end

  test "a wrong app key is refused the way Pusher refuses it", %{tmp_dir: dir} do
    start()
    url = String.replace(Instance.pusher_url(), Server.pusher().app_key, "not-the-key")
    {_result, lines} = record(dir, [], 500, url)

    assert [%{"event" => "pusher:error", "data" => %{"code" => 4001}}] = frames(lines, "in")
    assert %{"frame" => %{"event" => "stopped", "reason" => reason}} = List.last(lines)
    assert reason =~ "4001"
  end

  test "the disconnect fault closes sockets with 4200, for testing reconnects", %{tmp_dir: dir} do
    start(faults: [pusher_disconnect_after_s: 0.2])
    {_result, lines} = record(dir, ["chatrooms.1.v2"], 1_000)

    assert %{"frame" => %{"event" => "stopped", "reason" => reason}} = List.last(lines)
    assert reason =~ "4200"
  end

  test "a client that stops answering pings is dropped with 4201" do
    state = %{socket_id: "1.1", awaiting_pong: true, config: %{ping_ms: 1_000}}
    assert {:stop, :normal, {4201, _}, ^state} = Socket.handle_info(:ping, state)
  end

  test "a client's own ping gets a pong, and its pong clears the pending ping" do
    state = %{socket_id: "1.1", awaiting_pong: true, config: %{ping_ms: 1_000}}

    assert {:push, {:text, pong}, ^state} =
             Socket.handle_in({~s({"event":"pusher:ping","data":{}}), opcode: :text}, state)

    assert %{"event" => "pusher:pong", "data" => "{}"} = Jason.decode!(pong)

    assert {:ok, %{awaiting_pong: false}} =
             Socket.handle_in({~s({"event":"pusher:pong","data":{}}), opcode: :text}, state)
  end

  test "garbage from a client is ignored, not a crash" do
    state = %{socket_id: "1.1", awaiting_pong: false, config: %{ping_ms: 1_000}}

    assert {:ok, ^state} = Socket.handle_in({"not json", opcode: :text}, state)

    assert {:ok, ^state} =
             Socket.handle_in({~s({"event":"client-whatever"}), opcode: :text}, state)

    assert {:ok, ^state} = Socket.handle_in({<<1, 2, 3>>, opcode: :binary}, state)
  end

  test "only subscribed sockets get a channel's frames, until they leave" do
    start()
    topic = "chatrooms.1.v2"

    refute Hub.listened?(topic)
    :ok = Hub.join(topic)
    :ok = Hub.join(topic)
    assert Hub.listened?(topic)

    Hub.broadcast(topic, ["one"])
    Hub.broadcast("chatrooms.2.v2", ["not for us"])
    assert_receive {:pusher_frames, ["one"]}
    refute_receive {:pusher_frames, ["not for us"]}, 50

    # Joining twice doesn't mean receiving twice.
    refute_receive {:pusher_frames, ["one"]}, 50

    :ok = Hub.leave(topic)
    refute Hub.listened?(topic)
    Hub.broadcast(topic, ["two"])
    refute_receive {:pusher_frames, _}, 50
  end
end
