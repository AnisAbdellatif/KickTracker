defmodule Sim.Recorder.PusherTest do
  use ExUnit.Case, async: false

  alias Sim.Recorder.Pusher

  # A minimal Pusher server: confirms the connection, confirms subscriptions,
  # pings, sends one chat message, and replies to nothing else.
  defmodule FakePusher do
    @behaviour WebSock

    @impl true
    def init(test_pid) do
      established = %{
        "event" => "pusher:connection_established",
        "data" => ~s({"socket_id":"1.2"})
      }

      {:push, {:text, Jason.encode!(established)}, test_pid}
    end

    @impl true
    def handle_in({text, opcode: :text}, test_pid) do
      send(test_pid, {:client_sent, text})

      case Jason.decode!(text) do
        %{"event" => "pusher:subscribe", "data" => %{"channel" => channel}} ->
          chat = Jason.encode!(%{"content" => "hi", "sender" => %{"id" => 1}})

          frames = [
            {:text,
             Jason.encode!(%{
               "event" => "pusher_internal:subscription_succeeded",
               "channel" => channel
             })},
            {:text, Jason.encode!(%{"event" => "pusher:ping", "data" => %{}})},
            {:text,
             Jason.encode!(%{
               "event" => "App\\Events\\ChatMessageEvent",
               "channel" => channel,
               "data" => chat
             })}
          ]

          {:push, frames, test_pid}

        _ ->
          {:ok, test_pid}
      end
    end

    @impl true
    def handle_info(_message, test_pid), do: {:ok, test_pid}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule Router do
    @behaviour Plug
    def init(test_pid), do: test_pid
    def call(conn, test_pid), do: WebSockAdapter.upgrade(conn, FakePusher, test_pid, [])
  end

  @tag :tmp_dir
  test "connects, subscribes after connection_established, answers pings, records every frame", %{
    tmp_dir: dir
  } do
    server = start_supervised!({Bandit, plug: {Router, self()}, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert {:ok, lines} =
             Pusher.record("ws://127.0.0.1:#{port}/app/key?protocol=7",
               run: dir,
               name: "chan",
               channels: ["chatrooms.5.v2"],
               deadline_ms: System.monotonic_time(:millisecond) + 1_000
             )

    assert_received {:client_sent, subscribe}

    assert %{
             "event" => "pusher:subscribe",
             "data" => %{"channel" => "chatrooms.5.v2", "auth" => ""}
           } = Jason.decode!(subscribe)

    assert_received {:client_sent, pong}
    assert %{"event" => "pusher:pong"} = Jason.decode!(pong)

    recorded =
      dir
      |> Path.join("pusher/chan.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(recorded) == lines

    events =
      for %{"direction" => dir, "frame" => frame} <- recorded,
          is_binary(frame),
          do: {dir, Jason.decode!(frame)["event"]}

    assert {"in", "pusher:connection_established"} in events
    assert {"out", "pusher:subscribe"} in events
    assert {"in", "App\\Events\\ChatMessageEvent"} in events
    assert {"out", "pusher:pong"} in events
    assert %{"frame" => %{"event" => "deadline"}} = List.last(recorded)
  end

  # Over a real network the 101 response and Pusher's first frame often come
  # in one read. This server makes that certain by sending both in a single
  # write, then records what the client sends back.
  defp one_packet_server(test_pid) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      [_, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, request)

      accept =
        :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

      frame = ~s({"event":"pusher:connection_established","data":"{}"})

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
          "Sec-WebSocket-Accept: #{accept}\r\n\r\n",
          <<0x81, byte_size(frame)>>,
          frame
        ])

      {:ok, from_client} = :gen_tcp.recv(socket, 0, 5_000)
      send(test_pid, {:client_bytes, from_client})
      Process.sleep(2_000)
    end)

    port
  end

  @tag :tmp_dir
  test "a first frame arriving together with the 101 response is not lost", %{tmp_dir: dir} do
    port = one_packet_server(self())

    assert {:ok, _} =
             Pusher.record("ws://127.0.0.1:#{port}/app/key",
               run: dir,
               name: "chan",
               channels: ["chatrooms.5.v2"],
               deadline_ms: System.monotonic_time(:millisecond) + 800
             )

    # The client answered connection_established with a (masked) subscribe frame.
    assert_received {:client_bytes, <<0x81, _::binary>>}

    frames =
      dir
      |> Path.join("pusher/chan.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&is_binary(&1["frame"]))
      |> Enum.map(&{&1["direction"], Jason.decode!(&1["frame"])["event"]})

    assert frames == [{"in", "pusher:connection_established"}, {"out", "pusher:subscribe"}]
  end

  test "an unreachable server is an error, not a hang" do
    assert {:error, _} =
             Pusher.record("ws://127.0.0.1:1/app/key",
               run: "unused",
               name: "x",
               channels: [],
               deadline_ms: System.monotonic_time(:millisecond) + 1_000
             )
  end
end
