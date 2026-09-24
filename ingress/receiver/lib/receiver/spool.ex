defmodule Receiver.Spool do
  @moduledoc """
  Envelopes waiting for RabbitMQ, on the receiver's own disk (SQLite). When
  the queue is unreachable or doesn't confirm, the receiver writes here and
  still answers Kick 200: the delivery is safe, just not forwarded yet.
  `Receiver.Forwarder` drains it.

  A write counts only once it is on disk: WAL mode with `synchronous=FULL`,
  so a crash or power cut right after answering Kick loses nothing. The
  same message id is stored once, however often Kick retries it.
  """

  use GenServer

  alias Exqlite.Sqlite3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Stores an envelope. Storing the same message id again is a no-op."
  @spec put(String.t(), String.t(), binary(), GenServer.server()) :: :ok | {:error, term()}
  def put(message_id, routing_key, payload, server \\ __MODULE__) do
    GenServer.call(server, {:put, message_id, routing_key, payload})
  catch
    :exit, reason -> {:error, {:spool_unavailable, reason}}
  end

  @doc "Up to `limit` stored envelopes, oldest first, as `{id, message_id, routing_key, payload}`."
  @spec take(pos_integer(), GenServer.server()) :: [{integer(), String.t(), String.t(), binary()}]
  def take(limit, server \\ __MODULE__), do: GenServer.call(server, {:take, limit})

  @doc "Removes one stored envelope, once it has been forwarded."
  @spec delete(integer(), GenServer.server()) :: :ok
  def delete(id, server \\ __MODULE__), do: GenServer.call(server, {:delete, id})

  @doc "How many envelopes are waiting."
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server \\ __MODULE__), do: GenServer.call(server, :count)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)

    :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(db, "PRAGMA synchronous = FULL")

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS spool (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id TEXT NOT NULL UNIQUE,
        routing_key TEXT NOT NULL,
        payload BLOB NOT NULL,
        stored_at TEXT NOT NULL
      )
      """)

    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:put, message_id, routing_key, payload}, _from, %{db: db} = state) do
    result =
      run(
        db,
        "INSERT OR IGNORE INTO spool (message_id, routing_key, payload, stored_at) VALUES (?1, ?2, ?3, ?4)",
        [
          message_id,
          routing_key,
          {:blob, payload},
          DateTime.utc_now() |> DateTime.to_iso8601()
        ]
      )

    {:reply, result, state}
  end

  def handle_call({:take, limit}, _from, %{db: db} = state) do
    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "SELECT id, message_id, routing_key, payload FROM spool ORDER BY id LIMIT ?1"
      )

    :ok = Sqlite3.bind(stmt, [limit])
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    {:reply, Enum.map(rows, &List.to_tuple/1), state}
  end

  def handle_call({:delete, id}, _from, %{db: db} = state) do
    {:reply, run(db, "DELETE FROM spool WHERE id = ?1", [id]), state}
  end

  def handle_call(:count, _from, %{db: db} = state) do
    {:ok, stmt} = Sqlite3.prepare(db, "SELECT count(*) FROM spool")
    {:row, [count]} = Sqlite3.step(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    {:reply, count, state}
  end

  @impl true
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  defp run(db, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(stmt, params),
         :done <- Sqlite3.step(db, stmt),
         :ok <- Sqlite3.release(db, stmt) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end
end
