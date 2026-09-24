defmodule KickTracker.Tracking.Manager do
  @moduledoc """
  Keeps one `ChannelSup` running per active channel: at boot, whenever the
  tracked set changes (`"channels:changed"`), and every minute as a safety
  net, so a lost broadcast only delays a change.

  One channel can't take the others down. A `ChannelSup` is `:temporary`:
  when its processes keep crashing it gives up on its own (its own restart
  limit), which spends nothing of the supervisor all channels share. This
  process watches each one; a channel that stopped without being asked to
  is **quarantined**: logged as an error (so it is notified), shown in the
  collector's status (`:quarantined_channels`), and started again only
  after a backoff that doubles with each failure in a row (1 minute, 2,
  4, ... up to an hour). A channel that then runs for 10 minutes starts
  its count over.

  The tracked set comes from `Collector.Tracked`: when the database can't
  be read, the channels last known keep running, and nothing here fails.
  """

  use GenServer
  require Logger

  alias KickTracker.{Channels, Tracking}
  alias KickTracker.Collector.{Status, Tracked}
  alias KickTracker.Tracking.ChannelSup

  @resync_ms 60_000
  @base_backoff_ms 60_000
  @max_backoff_ms 3_600_000
  @stable_ms 600_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Syncs now. For tests."
  @spec sync(GenServer.server()) :: :ok
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync, 30_000)

  @doc """
  Stops a channel's processes now and returns once they have stopped
  (their last chat written to the journal), and drops the channel from
  the tracked list the sources poll. For a channel being deleted: its row
  must already be inactive, or the next sync starts it again. A no-op
  where collection doesn't run.
  """
  @spec stop_channel(integer(), GenServer.server()) :: :ok
  def stop_channel(channel_id, server \\ __MODULE__) do
    GenServer.call(server, {:stop_channel, channel_id}, 60_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "The quarantined channels: `%{channel_id => %{failures:, retry_at:}}`."
  @spec quarantined(GenServer.server()) :: map()
  def quarantined(server \\ __MODULE__), do: GenServer.call(server, :quarantined)

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(KickTracker.PubSub, Channels.topic())

    state = %{
      on_change: Keyword.get(opts, :on_change, &on_change/0),
      child: Keyword.get(opts, :child, ChannelSup),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @base_backoff_ms),
      stable_ms: Keyword.get(opts, :stable_ms, @stable_ms),
      # monitor ref => {channel id, pid, started (monotonic ms)}
      watched: %{},
      # channel id => %{failures:, retry_at: monotonic ms, since: DateTime}
      quarantine: %{},
      # pids this process stopped on purpose
      stopping: MapSet.new()
    }

    {:ok, state, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    state = do_sync(state)
    # At boot too, so a fresh collector gets its webhooks at once rather
    # than at the next scheduled sync.
    state.on_change.()
    Process.send_after(self(), :resync, @resync_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, do_sync(state)}

  def handle_call(:quarantined, _from, state) do
    {:reply, Map.new(state.quarantine, fn {id, q} -> {id, Map.take(q, [:failures, :since])} end),
     state}
  end

  def handle_call({:stop_channel, channel_id}, _from, state) do
    Tracked.refresh()

    state =
      case Tracking.whereis({:channel_sup, channel_id}) do
        nil -> state
        pid -> stop_sup(state, pid)
      end

    {:reply, :ok, %{state | quarantine: Map.delete(state.quarantine, channel_id)}}
  end

  @impl true
  def handle_info(:resync, state) do
    Process.send_after(self(), :resync, @resync_ms)
    {:noreply, do_sync(state)}
  end

  # A quarantined channel's wait is over.
  def handle_info(:retry, state), do: {:noreply, do_sync(state)}

  def handle_info({change, _channel_id}, state) when change in [:added, :removed] do
    state = do_sync(state)
    state.on_change.()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.watched, ref) do
      {nil, _} ->
        {:noreply, state}

      {{channel_id, ^pid, started}, watched} ->
        state = %{state | watched: watched}

        if MapSet.member?(state.stopping, pid) do
          {:noreply, %{state | stopping: MapSet.delete(state.stopping, pid)}}
        else
          {:noreply, quarantine(state, channel_id, started, reason)}
        end
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- syncing -----------------------------------------------------------------

  defp do_sync(state) do
    {freshness, active} = Tracked.refresh()
    active_ids = MapSet.new(active, & &1.id)

    # Each ChannelSup registers as {:channel_sup, channel id}. (A dynamic
    # supervisor doesn't report its children's ids.)
    running =
      Registry.select(Tracking.registry(), [
        {{{:channel_sup, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])

    # Watch what runs (a restarted Manager finds them running).
    state = Enum.reduce(running, state, fn {id, pid}, state -> watch(state, id, pid) end)

    # Only a list the database gave stops channels: a stale one never does.
    state =
      Enum.reduce(running, state, fn {id, pid}, state ->
        if freshness == :ok and not MapSet.member?(active_ids, id),
          do: stop_sup(state, pid),
          else: state
      end)

    # A channel no longer tracked has nothing to wait for.
    quarantine =
      if freshness == :ok,
        do: Map.filter(state.quarantine, fn {id, _} -> MapSet.member?(active_ids, id) end),
        else: state.quarantine

    state = %{state | quarantine: quarantine}
    running_ids = MapSet.new(running, &elem(&1, 0))
    now = System.monotonic_time(:millisecond)

    state =
      for channel <- active,
          not MapSet.member?(running_ids, channel.id),
          due?(state, channel.id, now),
          reduce: state do
        state -> start(state, channel)
      end

    publish(state)
  end

  defp start(state, channel) do
    case DynamicSupervisor.start_child(Tracking.ChannelsSupervisor, {state.child, channel}) do
      {:ok, pid} ->
        watch(state, channel.id, pid)

      {:error, {:already_started, pid}} ->
        watch(state, channel.id, pid)

      error ->
        Logger.error("could not start channel #{channel.id}: #{inspect(error)}")
        quarantine(state, channel.id, System.monotonic_time(:millisecond), error)
    end
  end

  defp watch(state, channel_id, pid) do
    if Enum.any?(state.watched, fn {_, {_, p, _}} -> p == pid end) do
      state
    else
      ref = Process.monitor(pid)
      started = System.monotonic_time(:millisecond)
      %{state | watched: Map.put(state.watched, ref, {channel_id, pid, started})}
    end
  end

  # Synchronous: returns once the channel's processes have stopped.
  defp stop_sup(state, pid) do
    state = %{state | stopping: MapSet.put(state.stopping, pid)}
    DynamicSupervisor.terminate_child(Tracking.ChannelsSupervisor, pid)
    state
  end

  # --- quarantine --------------------------------------------------------------

  defp due?(state, channel_id, now) do
    case state.quarantine[channel_id] do
      nil -> true
      %{retry_at: retry_at} -> now >= retry_at
    end
  end

  defp quarantine(state, channel_id, started, reason) do
    now = System.monotonic_time(:millisecond)
    previous = state.quarantine[channel_id]

    # A channel that ran a good while before failing starts its count over.
    failures =
      if previous == nil or now - started >= state.stable_ms,
        do: 1,
        else: previous.failures + 1

    wait_ms = min(state.base_backoff_ms * Integer.pow(2, min(failures, 20) - 1), @max_backoff_ms)

    Logger.error(
      "channel #{channel_id}: its processes stopped (#{inspect(reason, limit: 5)}), " <>
        "failure #{failures} in a row; quarantined, restarted in #{div(wait_ms, 1000)}s"
    )

    q = %{failures: failures, retry_at: now + wait_ms, since: DateTime.utc_now()}
    Process.send_after(self(), :retry, wait_ms + 10)
    publish(%{state | quarantine: Map.put(state.quarantine, channel_id, q)})
  end

  # For the health page (through the collector's status).
  defp publish(state) do
    Status.put(
      :quarantined_channels,
      Map.new(state.quarantine, fn {id, q} -> {id, Map.take(q, [:failures, :since])} end)
    )

    state
  end

  # The webhook subscriptions follow the tracked set. (Queued in the
  # database: if it is away, the 15-minute sync catches up.)
  defp on_change do
    KickTracker.Workers.SubscriptionSync.enqueue()
  rescue
    error -> Logger.warning("could not queue a subscription sync: #{Exception.message(error)}")
  end
end
