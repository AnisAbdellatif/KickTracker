defmodule Receiver.HTTPReuseTest do
  @moduledoc """
  A request that times out must not leave its connection in the pool.

  With Finch 0.23 and Mint 1.11 it did: the timed-out connection went back
  to the pool still open, and the next request on it (Kick's public key,
  a peer's health) read the late answer to the first one and crashed
  (`no case clause matching: {:status, ref, 200}`). Fixed in Finch 0.24
  (#397).
  """

  use ExUnit.Case, async: true

  @late_ms 300

  test "the request after a timeout gets its own answer, not the late one" do
    port = serve(fn n -> if n == 1, do: Process.sleep(@late_ms) end)

    get = fn ->
      Req.get("http://127.0.0.1:#{port}/", retry: false, receive_timeout: div(@late_ms * 2, 3))
    end

    assert {:error, %Req.TransportError{reason: :timeout}} = get.()
    assert {:ok, %{status: 200, body: "answer 2"}} = get.()
  end

  # A keep-alive HTTP/1.1 server answering its nth request with
  # "answer n" after `before_answer.(n)`.
  defp serve(before_answer) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, count} = Agent.start_link(fn -> 0 end)
    start_supervised!({Task, fn -> accept(listen, count, before_answer) end})
    port
  end

  defp accept(listen, count, before_answer) do
    {:ok, socket} = :gen_tcp.accept(listen)
    spawn_link(fn -> answer(socket, "", count, before_answer) end)
    accept(listen, count, before_answer)
  end

  defp answer(socket, buffer, count, before_answer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [_request, rest] ->
        n = Agent.get_and_update(count, &{&1 + 1, &1 + 1})
        before_answer.(n)
        body = "answer #{n}"

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body
        )

        answer(socket, rest, count, before_answer)

      [_partial] ->
        case :gen_tcp.recv(socket, 0) do
          {:ok, data} -> answer(socket, buffer <> data, count, before_answer)
          {:error, _closed} -> :ok
        end
    end
  end
end
