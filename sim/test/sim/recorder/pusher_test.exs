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
