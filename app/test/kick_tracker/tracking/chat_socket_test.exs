defmodule KickTracker.Tracking.ChatSocketTest do
  @moduledoc "A chat server that accepts the connection but never answers the upgrade isn't waited on forever."

  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias KickTracker.Tracking.ChatSocket

  setup do
    # Accepts connections, answers nothing.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    acceptor =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          send(test, :accepted)
          socket
        end)
        |> Enum.to_list()
      end)

    kick = Application.get_env(:kick_tracker, :kick)
    collector = Application.get_env(:kick_tracker, :collector, [])

    Application.put_env(
      :kick_tracker,
      :kick,
      Keyword.put(kick, :pusher_url, "ws://127.0.0.1:#{port}/app/test?protocol=7")
    )

    Application.put_env(
      :kick_tracker,
      :collector,
      Keyword.put(collector, :chat_connect_timeout_ms, 200)
    )

    on_exit(fn ->
      Application.put_env(:kick_tracker, :kick, kick)
      Application.put_env(:kick_tracker, :collector, collector)
      Process.exit(acceptor, :kill)
    end)

    start_supervised!({Registry, keys: :unique, name: KickTracker.Tracking.registry()})
    :ok
  end

  test "an upgrade that never completes is dropped and retried" do
    channel = %KickTracker.Channels.Channel{
      id: 1,
      kick_user_id: 2,
      slug: "somestreamer",
      chatroom_id: 3
    }

    pid = start_supervised!({ChatSocket, channel})

    assert_receive :accepted, 1_000
    # Timed out after 200ms, retried after the 1s backoff.
    assert_receive :accepted, 3_000
    refute ChatSocket.subscribed?(pid)
  end
end
