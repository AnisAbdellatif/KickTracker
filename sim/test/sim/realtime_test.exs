defmodule Sim.RealtimeTest do
  @moduledoc """
  The fake realtime server (Kick's Centrifugo chat), driven by kicksdk's
  session, the client the app uses (`Sim.RealtimeClient`), so a protocol
  mismatch shows up as a failure here rather than in the app later.
  """

  use ExUnit.Case, async: false

  alias Sim.Channel.Server, as: ChannelServer
  alias Sim.Realtime.{Hub, Socket}
  alias Sim.{Clock, Instance, RealtimeClient, Scenario, Server}

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
       ] ++ Keyword.take(extra, [:realtime])}
    )

    Scenario.channel(scenario, @slug)
  end

  defp actions(result, name), do: for(%{"action" => ^name} = a <- result.actions, do: a)

  test "connects, subscribes, and receives a live stream's chat" do
    channel = start()
    feeds = Kicksdk.Realtime.chat_channels(channel.chatroom_id, channel.channel_id)
    chat_feed = "chatrooms.#{channel.chatroom_id}.v2"

    # A minute of the stream, once the socket listens.
    Task.start_link(fn ->
      Enum.find(1..100, fn _ ->
        Process.sleep(20)
        Hub.listened?(chat_feed)
      end)

      Server.put_clock(Clock.new(sim_start: DateTime.add(@live, 60, :second)))
      ChannelServer.tick(@slug)
    end)

    result = RealtimeClient.run(feeds ++ ["private-chatroom_#{channel.chatroom_id}"], 1_500)

    assert [_] = actions(result, "connected")

    assert Enum.map(actions(result, "subscribed"), & &1["channel"]) |> Enum.sort() ==
             Enum.sort(feeds)

    assert [%{"channel" => "private-" <> _, "code" => 103}] = actions(result, "subscribe_failed")
    assert result.closed == nil

    chat =
      for {^chat_feed, "App\\Events\\ChatMessageEvent", event} <- RealtimeClient.events(result),
          do: event

    assert chat != [], "a minute of a 3 000-viewer stream should have chat"
    assert Enum.all?(chat, &(&1["type"] == "chat_message"))
    assert Enum.all?(chat, &(&1["chatroom_id"] == channel.chatroom_id))
    assert Enum.all?(chat, &(&1["created_at"] =~ ~r/\+00:00$/))
    assert Enum.all?(chat, &is_integer(&1["sender"]["id"]))

    # Kick's data travels as JSON text inside the JSON, as recorded.
    data = for %{"action" => "event", "data" => data} <- result.actions, do: data
    assert Enum.all?(data, &is_binary/1)
  end

  test "the handshake answers have the recorded shape" do
    start()
    result = RealtimeClient.run(["chatrooms.1.v2", "private-chatroom_1"], 400)

    replies =
      Enum.flat_map(result.in, &String.split(&1, "\n", trim: true)) |> Enum.map(&Jason.decode!/1)

    # As recorded (kicksdk's fixtures/realtime/20261013T040322Z-*.jsonl).
    assert [%{"id" => 1, "connect" => connect}] = Enum.filter(replies, & &1["connect"])

    assert Map.keys(connect) |> Enum.sort() ==
             ~w(client expires ping pong ttl version)

    assert %{"expires" => true, "ttl" => 2_700, "ping" => 25, "pong" => true} = connect
    assert %{"subscribe" => %{}} = Enum.find(replies, & &1["subscribe"])

    assert %{"error" => %{"code" => 103, "message" => "permission denied"}} =
             Enum.find(replies, & &1["error"])
  end

  test "the server pings, and a client that answers stays connected" do
    start(realtime: [ping_s: 1])
    result = RealtimeClient.run(["chatrooms.1.v2"], 2_500)

    assert "{}" in result.in
    assert "{}" in result.out
    assert result.closed == nil
  end

  test "a token is refreshed before it runs out; one that runs out ends the connection" do
    start(realtime: [ttl_s: 2])
    refreshed = RealtimeClient.run(["chatrooms.1.v2"], 3_000)

    assert Enum.any?(refreshed.out, &(&1 =~ ~s("refresh")))
    assert refreshed.closed == nil

    expired = RealtimeClient.run(["chatrooms.1.v2"], 3_000, refresh: false)
    assert expired.closed == {3005, "token expired"}
  end

  test "a handshake from anywhere but kick.com is refused, as Kick refuses it" do
    start()
    assert %{closed: {:refused, 403}} = RealtimeClient.run([], 500, origin: "https://example.org")
  end

  test "the disconnect fault closes sockets as a shutdown does, for testing reconnects" do
    start(faults: [realtime_disconnect_after_s: 0.2])
    assert %{closed: {3001, "shutdown"}} = RealtimeClient.run(["chatrooms.1.v2"], 1_000)
  end

  test "a connection asked for in general or for a channel is served here" do
    start()

    for path <- ["/connection", "/channels/1/chat/connection"] do
      body =
        Req.post!(Instance.realtime_url() <> path, json: %{"client" => %{"id" => "c"}}).body

      assert %{"data" => %{"connections" => [%{"provider" => "centrifugo"} = c]}} = body
      assert c["credentials"]["url"] =~ ~r{^ws://127\.0\.0\.1:\d+/connection/websocket$}
    end

    assert Req.post!(Instance.realtime_url() <> "/auth/connection", json: %{}, retry: false).status ==
             400
  end

  describe "a socket on its own" do
    defp socket(extra \\ %{}),
      do:
        Map.merge(
          %{config: %{ping_s: 25, ttl_s: 60}, client: "c", awaiting_pong: false, expires: nil},
          extra
        )

    defp send_in(text, state), do: Socket.handle_in({text, opcode: :text}, state)

    test "a client that stops answering pings is dropped (3012); its pong clears the ping" do
      assert {:stop, :normal, {3012, _}, _} =
               Socket.handle_info(:ping, socket(%{awaiting_pong: true}))

      assert {:push, [], %{awaiting_pong: false}} = send_in("{}", socket(%{awaiting_pong: true}))
    end

    test "a connect with a token it didn't issue is refused (3500)" do
      start()

      assert {:stop, :normal, {3500, _}, [], _} =
               send_in(
                 ~s({"id":1,"connect":{"token":"made-up","name":"js"}}),
                 socket(%{client: nil})
               )
    end

    test "commands sharing a frame are answered one by one" do
      start()

      assert {:push, [{:text, a}, {:text, b}], _} =
               send_in(
                 ~s({"id":2,"subscribe":{"channel":"a"}}\n{"id":3,"subscribe":{"channel":"b"}}),
                 socket()
               )

      assert [Jason.decode!(a), Jason.decode!(b)] == [
               %{"id" => 2, "subscribe" => %{}},
               %{"id" => 3, "subscribe" => %{}}
             ]
    end

    test "garbage from a client is ignored, not a crash" do
      state = socket()
      assert {:push, [], ^state} = send_in("not json", state)
      assert {:push, [], ^state} = send_in(~s({"whatever":1}), state)
      assert {:ok, ^state} = Socket.handle_in({<<1, 2, 3>>, opcode: :binary}, state)
    end
  end

  test "a publication carries Kick's event and its data as text" do
    frame = Socket.publication("chatrooms.1.v2", "App\\Events\\X", ~s({"a":1}))

    assert Jason.decode!(frame) == %{
             "push" => %{
               "channel" => "chatrooms.1.v2",
               "pub" => %{
                 "data" => %{"event" => "App\\Events\\X", "data" => ~s({"a":1})},
                 "tags" => %{"event" => "App\\Events\\X"}
               }
             }
           }
  end

  test "only subscribed sockets get a feed's frames, until they leave" do
    start()
    topic = "chatrooms.1.v2"

    refute Hub.listened?(topic)
    :ok = Hub.join(topic)
    :ok = Hub.join(topic)
    assert Hub.listened?(topic)

    Hub.broadcast(topic, ["one"])
    Hub.broadcast("chatrooms.2.v2", ["not for us"])
    assert_receive {:realtime_frames, ["one"]}
    refute_receive {:realtime_frames, ["not for us"]}, 50

    # Joining twice doesn't mean receiving twice.
    refute_receive {:realtime_frames, ["one"]}, 50

    :ok = Hub.leave(topic)
    refute Hub.listened?(topic)
    Hub.broadcast(topic, ["two"])
    refute_receive {:realtime_frames, _}, 50
  end
end
