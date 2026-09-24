defmodule KickTracker.Collector.Journal do
  @moduledoc """
  Every write the collector makes, on its own disk first (project.md
  §10.2): a SQLite file of operations (`KickTracker.Collector.Ops`), in
  order, each tagged with the lease epoch it was made under and when.
  `Collector.Writer` applies them to Postgres and deletes them.

  So collection doesn't depend on the database being up: a database
  restart, a slow migration or a network blip only delays the writes, and
  a collector restarted meanwhile finds its journal where it left it.
  A write counts once it is on disk (WAL, `synchronous=FULL`).

  The journal also keeps small snapshots (`put/2`, `get/1`): the tracked
  channels and each channel's stream state, which the collector falls
  back on when it starts while the database is unreachable.

  Configured by `:kick_tracker, :collector, :journal`: a file path, or
  `:direct` to apply each write at once in the caller (tests; there is
  then nothing to replay).
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias KickTracker.Collector

  @type entry :: {pos_integer(), non_neg_integer(), DateTime.t(), term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Where writes go: a path, or `:direct`."
  def mode, do: Keyword.get(Application.get_env(:kick_tracker, :collector, []), :journal, :direct)

  @doc """
  Records writes, in order, under the current epoch. Returns once they
  are on disk (or, `:direct`, applied).
  """
  @spec append([term()]) :: :ok
  def append([]), do: :ok

  def append(ops) when is_list(ops) do
    case mode() do
      :direct -> Collector.Ops.apply_all!(ops)
      _path -> GenServer.call(__MODULE__, {:append, ops, Collector.epoch()}, 15_000)
    end
  end

  @doc "Records writes under `epoch` in a given journal (tools and tests)."
  @spec append_to(GenServer.server(), [term()], non_neg_integer()) :: :ok
  def append_to(server, ops, epoch), do: GenServer.call(server, {:append, ops, epoch}, 15_000)

  @doc "Up to `limit` writes, oldest first."
  @spec take(pos_integer(), GenServer.server()) :: [entry()]
  def take(limit, server \\ __MODULE__), do: GenServer.call(server, {:take, limit}, 15_000)

  @doc "Forgets every write up to and including `id` (applied)."
  @spec delete_through(pos_integer(), GenServer.server()) :: :ok
  def delete_through(id, server \\ __MODULE__),
    do: GenServer.call(server, {:delete_through, id}, 15_000)

  @doc "Sets a write aside for good, with why it could not be applied."
  @spec bury(pos_integer(), String.t(), GenServer.server()) :: :ok
  def bury(id, error, server \\ __MODULE__),
    do: GenServer.call(server, {:bury, id, error}, 15_000)

  @doc "How many writes wait, since when, and how many were set aside."
  @spec stats(GenServer.server()) :: %{
          depth: non_neg_integer(),
          oldest_at: DateTime.t() | nil,
          buried: non_neg_integer()
        }
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats, 5_000)
  catch
    :exit, _ -> %{depth: 0, oldest_at: nil, buried: 0}
  end

  @doc "This journal's identity (a new file is a new journal)."
  @spec id(GenServer.server()) :: String.t()
  def id(server \\ __MODULE__), do: GenServer.call(server, :id)

  @doc "Keeps a snapshot under `key`. Best effort: never fails the caller."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    GenServer.cast(__MODULE__, {:put, key, value})
  catch
    _, _ -> :ok
  end

  @doc "A snapshot kept with `put/2`, or nil."
  @spec get(term()) :: term() | nil
  def get(key) do
    GenServer.call(__MODULE__, {:get, key}, 5_000)
  catch
    :exit, _ -> nil
  end

  # --- server ------------------------------------------------------------------

  @impl true
  # The path comes from configuration (COLLECTOR_JOURNAL).
  # sobelow_skip ["Traversal.FileModule"]
  def init(opts) do
    case Keyword.get(opts, :path, mode()) do
      :direct ->
        {:ok, %{db: nil, kv: %{}, id: "direct"}}

      path ->
        File.mkdir_p!(Path.dirname(path))
        {:ok, db} = Sqlite3.open(path)
        :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
        :ok = Sqlite3.execute(db, "PRAGMA synchronous = FULL")

        :ok =
          Sqlite3.execute(db, """
          CREATE TABLE IF NOT EXISTS ops (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            epoch INTEGER NOT NULL,
            made_at INTEGER NOT NULL,
            op BLOB NOT NULL
          );
          CREATE TABLE IF NOT EXISTS buried (
            id INTEGER PRIMARY KEY,
            epoch INTEGER NOT NULL,
            made_at INTEGER NOT NULL,
            op BLOB NOT NULL,
            error TEXT NOT NULL,
            buried_at INTEGER NOT NULL
          );
          CREATE TABLE IF NOT EXISTS kv (key BLOB PRIMARY KEY, value BLOB NOT NULL);
          """)

        {:ok, %{db: db, kv: nil, id: journal_id(db)}}
    end
  end

  @impl true
  def handle_call({:append, ops, epoch}, _from, %{db: db} = state) do
    now = System.system_time(:microsecond)
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    try do
      Enum.each(ops, fn op ->
        :ok =
          run(db, "INSERT INTO ops (epoch, made_at, op) VALUES (?1, ?2, ?3)", [
            epoch,
            now,
            {:blob, :erlang.term_to_binary(op)}
          ])
      end)

      :ok = Sqlite3.execute(db, "COMMIT")
    rescue
      error ->
        Sqlite3.execute(db, "ROLLBACK")
        reraise error, __STACKTRACE__
    end

    Collector.Writer.wake()
    {:reply, :ok, state}
  end

  def handle_call({:take, _limit}, _from, %{db: nil} = state), do: {:reply, [], state}

  def handle_call({:take, limit}, _from, %{db: db} = state) do
    rows = all(db, "SELECT id, epoch, made_at, op FROM ops ORDER BY id LIMIT ?1", [limit])

    entries =
      for [id, epoch, made_at, op] <- rows,
          do: {id, epoch, DateTime.from_unix!(made_at, :microsecond), decode(op)}

    {:reply, entries, state}
  end

  def handle_call({:delete_through, id}, _from, %{db: db} = state) do
    {:reply, run(db, "DELETE FROM ops WHERE id <= ?1", [id]), state}
  end

  def handle_call({:bury, id, error}, _from, %{db: db} = state) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    :ok =
      run(
        db,
        "INSERT OR REPLACE INTO buried SELECT id, epoch, made_at, op, ?2, ?3 FROM ops WHERE id = ?1",
        [id, error, System.system_time(:microsecond)]
      )

    :ok = run(db, "DELETE FROM ops WHERE id = ?1", [id])
    :ok = Sqlite3.execute(db, "COMMIT")
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, %{db: nil} = state),
    do: {:reply, %{depth: 0, oldest_at: nil, buried: 0}, state}

  def handle_call(:stats, _from, %{db: db} = state) do
    [[depth, oldest]] = all(db, "SELECT count(*), min(made_at) FROM ops", [])
    [[buried]] = all(db, "SELECT count(*) FROM buried", [])
    oldest_at = oldest && DateTime.from_unix!(oldest, :microsecond)
    {:reply, %{depth: depth, oldest_at: oldest_at, buried: buried}, state}
  end

  def handle_call(:id, _from, state), do: {:reply, state.id, state}

  def handle_call({:get, key}, _from, %{db: nil} = state), do: {:reply, state.kv[key], state}

  def handle_call({:get, key}, _from, %{db: db} = state) do
    value =
      case all(db, "SELECT value FROM kv WHERE key = ?1", [{:blob, :erlang.term_to_binary(key)}]) do
        [[bin]] -> decode(bin)
        [] -> nil
      end

    {:reply, value, state}
  end

  @impl true
  def handle_cast({:put, key, value}, %{db: nil} = state),
    do: {:noreply, %{state | kv: Map.put(state.kv, key, value)}}

  def handle_cast({:put, key, value}, %{db: db} = state) do
    :ok =
      run(db, "INSERT OR REPLACE INTO kv (key, value) VALUES (?1, ?2)", [
        {:blob, :erlang.term_to_binary(key)},
        {:blob, :erlang.term_to_binary(value)}
      ])

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{db: nil}), do: :ok
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  # A random id stored with the file: the Writer's high-water mark in
  # Postgres is kept per journal, so a new file starts from zero safely.
  defp journal_id(db) do
    key = {:blob, :erlang.term_to_binary(:journal_id)}

    case all(db, "SELECT value FROM kv WHERE key = ?1", [key]) do
      [[bin]] ->
        decode(bin)

      [] ->
        id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

        :ok =
          run(db, "INSERT INTO kv (key, value) VALUES (?1, ?2)", [
            key,
            {:blob, :erlang.term_to_binary(id)}
          ])

        id
    end
  end

  # Only terms this app wrote to its own file; `:safe` refuses to create atoms.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode(bin), do: :erlang.binary_to_term(bin, [:safe])

  defp run(db, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(stmt, params),
         :done <- Sqlite3.step(db, stmt) do
      Sqlite3.release(db, stmt)
    end
  end

  defp all(db, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, params)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    rows
  end
end
