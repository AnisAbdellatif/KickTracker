defmodule KickTracker.Tracking.Manager do
  @moduledoc """
  Keeps one `ChannelSup` running per active channel: at boot, whenever the
  tracked set changes (`"channels:changed"`), and every few minutes as a
  safety net. A channel whose processes keep crashing is stopped by its
  own supervisor without affecting the others, and restarted here on the
  next sync.
  """

  use GenServer
  require Logger

  alias KickTracker.{Channels, Tracking}
  alias KickTracker.Tracking.ChannelSup

  @resync_ms 300_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Syncs now. For tests."
  @spec sync(GenServer.server()) :: :ok
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync, 30_000)

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(KickTracker.PubSub, Channels.topic())
    {:ok, %{on_change: Keyword.get(opts, :on_change, &on_change/0)}, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    do_sync()
    # At boot too, so a fresh collector gets its webhooks at once rather
    # than at the next scheduled sync.
    state.on_change.()
    Process.send_after(self(), :resync, @resync_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, do_sync(), state}

  @impl true
  def handle_info(:resync, state) do
    do_sync()
    Process.send_after(self(), :resync, @resync_ms)
    {:noreply, state}
  end

  def handle_info({change, _channel_id}, state) when change in [:added, :removed] do
    do_sync()
    state.on_change.()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp do_sync do
    active = Channels.list_active()
    active_ids = MapSet.new(active, & &1.id)

    # Each ChannelSup registers as {:channel_sup, channel id}. (A dynamic
    # supervisor doesn't report its children's ids.)
    running =
      Registry.select(Tracking.registry(), [
        {{{:channel_sup, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])

    for {id, pid} <- running, not MapSet.member?(active_ids, id) do
      DynamicSupervisor.terminate_child(Tracking.ChannelsSupervisor, pid)
    end

    running_ids = MapSet.new(running, &elem(&1, 0))

    for channel <- active, not MapSet.member?(running_ids, channel.id) do
      case DynamicSupervisor.start_child(Tracking.ChannelsSupervisor, {ChannelSup, channel}) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        error -> Logger.error("could not start channel #{channel.id}: #{inspect(error)}")
      end
    end

    :ok
  end

  # The webhook subscriptions follow the tracked set.
  defp on_change, do: KickTracker.Workers.SubscriptionSync.enqueue()
end
