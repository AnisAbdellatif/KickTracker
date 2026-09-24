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
        channels = replace(channels)
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

  @doc """
  One tracked channel's row as last known, or nil: from memory, or from
  the database when this isn't running (tests, a node without
  collection) or doesn't know it.
  """
  @spec get(integer()) :: Channel.t() | nil
  def get(channel_id) do
    case :ets.lookup(@table, :active) do
      [{:active, channels}] -> Enum.find(channels, &(&1.id == channel_id)) || from_db(channel_id)
      [] -> from_db(channel_id)
    end
  rescue
    ArgumentError -> from_db(channel_id)
  end

  @doc """
  Sets some fields of one channel's row (a rename, an id learnt) and
  returns the row as it now is, or nil if the channel isn't tracked here.
  Only the fields given change: a caller holding an older copy of the row
  can't undo what another learnt meanwhile. Serialized, so two updates at
  once both land.
  """
  @spec update(integer(), map() | keyword()) :: Channel.t() | nil
  def update(channel_id, fields) do
    GenServer.call(__MODULE__, {:update, channel_id, Map.new(fields)})
  catch
    :exit, _ -> nil
  end

  defp from_db(channel_id) do
    KickTracker.Repo.get(Channel, channel_id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # In this process, so it can't interleave with an `update/2`. An id
  # learnt a moment ago may still be on its way through the journal: the
  # database's nil doesn't forget it.
  defp replace(channels) do
    GenServer.call(__MODULE__, {:replace, channels})
  catch
    :exit, _ -> channels
  end

  defp keep_learnt_ids(fresh, known) do
    known = Map.new(known, &{&1.id, &1})

    Enum.map(fresh, fn c ->
      case known[c.id] do
        nil ->
          c

        old ->
          %{
            c
            | kick_channel_id: c.kick_channel_id || old.kick_channel_id,
              chatroom_id: c.chatroom_id || old.chatroom_id
          }
      end
    end)
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

  @impl true
  def handle_call({:replace, channels}, _from, state) do
    channels = keep_learnt_ids(channels, active())
    store(channels)
    {:reply, channels, state}
  end

  def handle_call({:update, channel_id, fields}, _from, state) do
    case :ets.lookup(@table, :active) do
      [{:active, channels}] ->
        case Enum.find(channels, &(&1.id == channel_id)) do
          nil ->
            {:reply, nil, state}

          channel ->
            updated = struct(channel, fields)
            store(Enum.map(channels, &if(&1.id == channel_id, do: updated, else: &1)))
            {:reply, updated, state}
        end

      [] ->
        {:reply, nil, state}
    end
  end
end
