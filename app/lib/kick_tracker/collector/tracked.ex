defmodule KickTracker.Collector.Tracked do
  @moduledoc """
  The channels this collector tracks, in memory, so the sources and the
  Manager don't need the database for every cycle (project.md §10.2).

  `refresh/0` reads the active channels from Postgres and keeps a copy in
  the journal; when the database can't be read, the last list known
  stays in use (from memory, or from the journal after a restart), so a
  collector that starts during a database outage still collects.
  """

  use GenServer
  require Logger

  alias KickTracker.Channels
  alias KickTracker.Channels.Channel
  alias KickTracker.Collector.Journal

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Reloads from the database. `{:ok, channels}` when it answered,
  `{:stale, channels}` with the last known list when it didn't.
  """
  @spec refresh() :: {:ok | :stale, [Channel.t()]}
  def refresh do
    case safe_list_active() do
      {:ok, channels} ->
        store(channels)
        Journal.put(:tracked_channels, channels)
        {:ok, channels}

      {:error, reason} ->
        channels =
          case active() do
            [] -> Journal.get(:tracked_channels) || []
            known -> known
          end

        if channels != [] and active() == [], do: store(channels)
        Logger.warning("tracked channels from the last known list: #{inspect(reason, limit: 5)}")
        {:stale, channels}
    end
  end

  @doc "The active channels last known, by slug order of the database."
  @spec active() :: [Channel.t()]
  def active do
    case :ets.lookup(@table, :active) do
      [{:active, channels}] -> channels
      [] -> []
    end
  rescue
    # Not running (a node without collection, or a test starting pieces
    # alone): straight from the database.
    ArgumentError -> Channels.list_active()
  end

  @doc "Replaces one channel's row (a rename or an id learnt)."
  @spec put(Channel.t()) :: :ok
  def put(%Channel{} = channel) do
    case :ets.lookup(@table, :active) do
      [{:active, channels}] ->
        store(Enum.map(channels, &if(&1.id == channel.id, do: channel, else: &1)))

      [] ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp store(channels) do
    :ets.insert(@table, {:active, channels})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_list_active do
    {:ok, Channels.list_active()}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
