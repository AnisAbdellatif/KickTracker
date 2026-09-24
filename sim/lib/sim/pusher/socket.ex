defmodule Sim.Pusher.Socket do
  @moduledoc """
  One client connection to the fake Pusher, speaking the subset of the
  Pusher protocol Kick's chat uses (protocol 7):

    * on connect, `pusher:connection_established` with a socket id and an
      activity timeout, its `data` a JSON **string**;
    * `pusher:subscribe` (with `auth: ""`, public channels) answered by
      `pusher_internal:subscription_succeeded`;
    * `pusher:ping` answered by `pusher:pong`, and pings of its own that
      the client must answer, or it is disconnected with code 4201 as real
      Pusher does;
    * chat frames for subscribed channels, pushed by `Sim.Pusher.Hub`.

  A wrong app key gets `pusher:error` 4001 and is closed, and the
  `pusher_disconnect_after_s` fault closes sockets with 4200 ("reconnect
  immediately"), so a client's reconnect logic can be tested.
  """

  @behaviour WebSock

  alias Sim.Pusher.Hub
  alias Sim.Server

  @impl true
  def init(%{key_ok?: false}) do
    error =
      frame("pusher:error", %{
        "code" => 4001,
        "message" => "App key not in this cluster. Did you forget to specify the cluster?"
      })

    {:stop, :normal, {4001, "App key not in this cluster"}, [{:text, error}], %{}}
  end

  def init(_opts) do
    config = Server.pusher()
    Hub.connected()

    socket_id = "#{:rand.uniform(999_999_999)}.#{:rand.uniform(999_999_999)}"

    Process.send_after(self(), :ping, config.ping_ms)

    if config.disconnect_after_ms,
      do: Process.send_after(self(), :fault_disconnect, config.disconnect_after_ms)

    established =
      frame(
        "pusher:connection_established",
        Jason.encode!(%{
          "socket_id" => socket_id,
          "activity_timeout" => config.activity_timeout_s
        })
      )

    {:push, {:text, established}, %{socket_id: socket_id, awaiting_pong: false, config: config}}
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    case Jason.decode(text) do
      {:ok, %{"event" => "pusher:subscribe", "data" => %{"channel" => channel}}}
      when is_binary(channel) ->
        Hub.join(channel)
        {:push, {:text, frame("pusher_internal:subscription_succeeded", "{}", channel)}, state}

      {:ok, %{"event" => "pusher:unsubscribe", "data" => %{"channel" => channel}}}
      when is_binary(channel) ->
        Hub.leave(channel)
        {:ok, state}

      {:ok, %{"event" => "pusher:ping"}} ->
        {:push, {:text, frame("pusher:pong", "{}")}, state}

      {:ok, %{"event" => "pusher:pong"}} ->
        {:ok, %{state | awaiting_pong: false}}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:pusher_frames, frames}, state) do
    {:push, Enum.map(frames, &{:text, &1}), state}
  end

  # Real Pusher pings an idle client and drops it if no pong comes back
  # before the next ping.
  def handle_info(:ping, %{awaiting_pong: true} = state) do
    {:stop, :normal, {4201, "Pong reply not received"}, state}
  end

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, state.config.ping_ms)
    {:push, {:text, frame("pusher:ping", "{}")}, %{state | awaiting_pong: true}}
  end

  def handle_info(:fault_disconnect, state) do
    {:stop, :normal, {4200, "Please reconnect immediately"}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  @doc "Encodes a Pusher frame. `data` is passed as is: a string for server events, as Pusher sends them."
  @spec frame(String.t(), term(), String.t() | nil) :: String.t()
  def frame(event, data, channel \\ nil) do
    %{"event" => event, "data" => data}
    |> then(&if(channel, do: Map.put(&1, "channel", channel), else: &1))
    |> Jason.encode!()
  end
end
