defmodule KickTracker.Collector.Status do
  @moduledoc """
  How this collector is doing, in memory (an ETS table this process
  owns): its role and epoch, each source's last cycle, the writer's last
  success, the journal. Read by the status endpoint
  (`Collector.StatusPlug`), the heartbeat row (`Collector.Heartbeat`) and
  the leader's watchdog. Writes never fail the caller: with no table
  (tests starting pieces alone) they are dropped.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records `value` under `key`."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Merges `fields` into the map under `key`."
  @spec merge(term(), map()) :: :ok
  def merge(key, fields), do: put(key, Map.merge(get(key) || %{}, fields))

  @doc "The value under `key`, or nil."
  @spec get(term()) :: term()
  def get(key) do
    case :ets.lookup(@table, key) do
      [{_, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Everything, as a map."
  @spec all() :: map()
  def all do
    @table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
