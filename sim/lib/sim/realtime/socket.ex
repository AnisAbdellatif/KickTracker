defmodule Sim.Realtime.Socket do
  @moduledoc """
  One client connection to the fake realtime server, speaking the part of
  Centrifugo's JSON protocol that kick.com's chat uses, as recorded
  (kicksdk's `fixtures/realtime`, KICK.md §6):

    * `connect` with a token from `POST /api/v1/realtime/auth/connection`,
      answered with a client id, the token's lifetime (`ttl`) and the ping
      interval; a token it didn't issue is refused (close 3500);
    * `subscribe`, answered with `{}`; a `private-…` feed needs a user and
      is refused with error 103 "permission denied";
    * `refresh` with a new token before the old one runs out; a
      connection whose token runs out is closed (3005);
    * a ping (`{}`) every `ping_s`, which the client answers with `{}`, or
      it is dropped at the next one (3012);
    * publications on subscribed feeds, pushed by `Sim.Realtime.Hub`, Kick's
      own event inside: `{"event": <name>, "data": <JSON text>}`.

  Several commands can share a frame, a line each. The handshake itself is
  checked by the router (Origin). The close codes are Centrifugo's own;
  the `realtime_disconnect_after_s` fault and `Hub.disconnect_all/1` close
  sockets as a server shutting down does (3001), so a client's reconnect
  can be tested; `Hub.disconnect_all/1` also takes another code, a terminal
  one (3500-3999, 4500-4999) included, and can send it as a disconnect push
  before the close frame.
  """

  @behaviour WebSock

  alias Sim.Realtime.Hub
  alias Sim.Server

  # What Kick's server says it is.
  @version "6.9.7 PRO"

  @impl true
  def init(_opts) do
    config = Server.realtime()
    Hub.connected()

    if config.disconnect_after_ms,
      do: Process.send_after(self(), :fault_disconnect, config.disconnect_after_ms)

    {:ok, %{config: config, client: nil, awaiting_pong: false, expires: nil}}
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({[], state}, fn line, {replies, state} ->
      case command(Jason.decode(line), state) do
        {:reply, reply, state} -> {:cont, {[{:text, Jason.encode!(reply)} | replies], state}}
        {:ok, state} -> {:cont, {replies, state}}
        {:close, code, reason} -> {:halt, {:close, code, reason, replies, state}}
      end
    end)
    |> case do
      {replies, state} ->
        {:push, Enum.reverse(replies), state}

      {:close, code, reason, replies, state} ->
        {:stop, :normal, {code, reason}, Enum.reverse(replies), state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  # The client's pong.
  defp command({:ok, empty}, state) when empty == %{}, do: {:ok, %{state | awaiting_pong: false}}

  defp command({:ok, %{"id" => id, "connect" => %{} = connect}}, %{client: nil} = state) do
    if Server.valid_realtime_token?(connect["token"]) do
      client = uuid()
      Process.send_after(self(), :ping, state.config.ping_s * 1_000)
      state = expire_later(%{state | client: client})

      {:reply,
       %{
         "id" => id,
         "connect" => %{
           "client" => client,
           "version" => @version,
           "expires" => true,
           "ttl" => state.config.ttl_s,
           "ping" => state.config.ping_s,
           "pong" => true
         }
       }, state}
    else
      {:close, 3500, "invalid token"}
    end
  end

  # Nothing but a connect before the connection is accepted.
  defp command({:ok, %{"id" => _}}, %{client: nil}), do: {:close, 3501, "bad request"}

  defp command({:ok, %{"id" => id, "subscribe" => %{"channel" => "private-" <> _}}}, state),
    do:
      {:reply, %{"id" => id, "error" => %{"code" => 103, "message" => "permission denied"}},
       state}

  defp command({:ok, %{"id" => id, "subscribe" => %{"channel" => channel}}}, state)
       when is_binary(channel) do
    Hub.join(channel)
    {:reply, %{"id" => id, "subscribe" => %{}}, state}
  end

  defp command({:ok, %{"id" => id, "unsubscribe" => %{"channel" => channel}}}, state)
       when is_binary(channel) do
    Hub.leave(channel)
    {:reply, %{"id" => id, "unsubscribe" => %{}}, state}
  end

  defp command({:ok, %{"id" => id, "refresh" => %{} = refresh}}, state) do
    if Server.valid_realtime_token?(refresh["token"]) do
      reply = %{
        "client" => state.client,
        "version" => @version,
        "expires" => true,
        "ttl" => state.config.ttl_s
      }

      {:reply, %{"id" => id, "refresh" => reply}, expire_later(state)}
    else
      {:reply, %{"id" => id, "error" => %{"code" => 109, "message" => "token expired"}}, state}
    end
  end

  defp command(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:realtime_frames, frames}, state) do
    {:push, Enum.map(frames, &{:text, &1}), state}
  end

  # A ping the client didn't answer before the next one.
  def handle_info(:ping, %{awaiting_pong: true} = state),
    do: {:stop, :normal, {3012, "no pong"}, state}

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, state.config.ping_s * 1_000)
    {:push, {:text, "{}"}, %{state | awaiting_pong: true}}
  end

  def handle_info({:expired, ref}, %{expires: ref} = state),
    do: {:stop, :normal, {3005, "token expired"}, state}

  def handle_info(:fault_disconnect, state),
    do: handle_info({:disconnect, 3001, "shutdown", false}, state)

  # The close frame carries the code; with `push`, a disconnect push says
  # it first (the form kicksdk's session reads as its own "close").
  def handle_info({:disconnect, code, reason, false}, state),
    do: {:stop, :normal, {code, reason}, state}

  def handle_info({:disconnect, code, reason, true}, state) do
    push = %{"push" => %{"disconnect" => %{"code" => code, "reason" => reason}}}
    {:stop, :normal, {code, reason}, [{:text, Jason.encode!(push)}], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  @doc """
  A publication on a feed, as Kick sends one: `data` is Kick's event data
  as JSON text (a string inside the JSON, as Kick sends it).
  """
  @spec publication(String.t(), String.t(), String.t()) :: String.t()
  def publication(channel, event, data) do
    Jason.encode!(%{
      "push" => %{
        "channel" => channel,
        "pub" => %{
          "data" => %{"event" => event, "data" => data},
          "tags" => %{"event" => event}
        }
      }
    })
  end

  # The token runs out `ttl_s` after the connect or the last refresh.
  defp expire_later(state) do
    ref = make_ref()
    Process.send_after(self(), {:expired, ref}, state.config.ttl_s * 1_000)
    %{state | expires: ref}
  end

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      Bitwise.band(c, 0x0FFF),
      Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
      e
    ])
    |> IO.iodata_to_binary()
  end
end
