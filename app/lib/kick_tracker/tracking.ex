defmodule KickTracker.Tracking do
  @moduledoc """
  The live side of collection: one process per tracked channel, and the
  hand-off from the queue consumer to them.
  """

  alias KickTracker.Events.{Envelope, Handlers}

  @registry KickTracker.Tracking.Registry

  @doc "The registry that names each channel's processes by Kick broadcaster id."
  def registry, do: @registry

  @doc "A name for one of a channel's processes, in the registry."
  @spec via(term()) :: {:via, Registry, {module(), term()}}
  def via(key), do: {:via, Registry, {@registry, key}}

  @doc "The pid registered under this key, or nil."
  @spec whereis(term()) :: pid() | nil
  def whereis(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  catch
    # No registry (a node without the collector role).
    :error, _ -> nil
  end

  @doc """
  Hands newly stored stream status and metadata events to their channels'
  processes. One that isn't running simply doesn't get it: the event stays
  unprocessed in the database and is picked up when the process starts.
  """
  @spec dispatch([Envelope.t()]) :: :ok
  def dispatch(envelopes) do
    for e <- envelopes, Handlers.channel_state?(e), id = Handlers.broadcaster_id(e), id != nil do
      if pid = whereis({:channel, id}), do: send(pid, {:event, e})
    end

    :ok
  end
end
