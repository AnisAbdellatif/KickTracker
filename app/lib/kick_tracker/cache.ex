defmodule KickTracker.Cache do
  @moduledoc """
  The web role's query cache (project.md §13.5): expensive aggregates
  (leaderboards, KPI cards) kept for a while, keyed by query and period.
  An ETS table with a TTL per entry; expired entries are swept every
  minute. A lookup that misses runs the function in the caller.
  """

  use GenServer

  @table __MODULE__
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The cached value for `key`, or `fun.()` stored for `ttl_s` seconds.
  Without the cache running (a node that doesn't serve the site), just
  runs `fun`.
  """
  @spec fetch(term(), non_neg_integer(), (-> term())) :: term()
  def fetch(key, ttl_s, fun) do
    now = System.monotonic_time(:second)

    case lookup(key) do
      {:ok, value, expires} when expires > now ->
        value

      _ ->
        value = fun.()
        if running?(), do: :ets.insert(@table, {key, value, now + ttl_s})
        value
    end
  end

  @doc "A TTL for a period: short while it reaches into the last two days, long otherwise."
  @spec ttl_for(DateTime.t()) :: non_neg_integer()
  def ttl_for(to), do: if(DateTime.diff(DateTime.utc_now(), to) < 2 * 86_400, do: 60, else: 3600)

  @doc "Drops everything (after a correction or a rebuild)."
  def clear, do: if(running?(), do: :ets.delete_all_objects(@table))

  defp lookup(key) do
    case running?() && :ets.lookup(@table, key) do
      [{^key, value, expires}] -> {:ok, value, expires}
      _ -> :miss
    end
  end

  # Tests turn it off (config :kick_tracker, :cache, false): the database is
  # rolled back after each test, a cache wouldn't be.
  defp running?,
    do: Application.get_env(:kick_tracker, :cache, true) and :ets.whereis(@table) != :undefined

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
