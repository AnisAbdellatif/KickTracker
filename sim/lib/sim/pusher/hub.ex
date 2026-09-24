defmodule Sim.Pusher.Hub do
  @moduledoc """
  Routes Pusher frames to the sockets subscribed to a channel name such as
  `chatrooms.123.v2`. A thin layer over a duplicate-key `Registry`: a socket
  registers itself under each channel it subscribes to, and a broadcast
  goes to whoever is registered. A socket that dies leaves automatically.
  """

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc "Registers the calling socket for a channel. Subscribing twice is harmless."
  @spec join(String.t()) :: :ok
  def join(channel) do
    if not Enum.any?(Registry.lookup(__MODULE__, channel), fn {pid, _} -> pid == self() end) do
      {:ok, _} = Registry.register(__MODULE__, channel, nil)
    end

    :ok
  end

  @doc "Unregisters the calling socket from a channel."
  @spec leave(String.t()) :: :ok
  def leave(channel), do: Registry.unregister(__MODULE__, channel)

  @doc "Whether anyone is listening, so callers can skip building frames nobody will read."
  @spec listened?(String.t()) :: boolean()
  def listened?(channel), do: Registry.lookup(__MODULE__, channel) != []

  @doc "Sends already-encoded frames to every socket subscribed to the channel."
  @spec broadcast(String.t(), [String.t()]) :: :ok
  def broadcast(_channel, []), do: :ok

  def broadcast(channel, frames) do
    Registry.dispatch(__MODULE__, channel, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:pusher_frames, frames})
    end)
  end
end
