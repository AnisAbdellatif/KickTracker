defmodule KickTracker.Collector.Writer do
  @moduledoc """
  Applies the `Collector.Journal` to Postgres (project.md §10.2): oldest
  first, in batches, each batch in one transaction, then forgets them.

    * **Exactly once.** Each batch moves this journal's high-water mark
      (`collector_journal_marks`) in the same transaction, so a crash
      between the commit and the journal delete replays nothing.
    * **The database away** (connection refused, restarting, a lock
      timeout during a migration) is waited out with backoff from 1s to
      30s; the writes stay on disk.
    * **A write that can never apply** is found by retrying the batch one
      write at a time, and set aside (`Journal.bury/2`) so it can't block
      the ones behind it; the health page and alerts show the count.
    * **Fencing.** A write made by a leader after a newer one took over
      (`Collector.Lease.stale?/3`) is dropped, so a split second of two
      collectors can't double anything.

  On shutdown it keeps writing for a few seconds; what is left waits on
  disk for the next start.
  """

  use GenServer
  require Logger

  alias KickTracker.{Collector, Repo}
  alias KickTracker.Collector.{Journal, Lease, Ops, Status}

  @batch 500
  @idle_ms 1_000
  @max_backoff_ms 30_000

  # Postgres errors that mean "later", not "never".
  @transient ~w(admin_shutdown crash_shutdown cannot_connect_now too_many_connections
                lock_not_available deadlock_detected serialization_failure query_canceled
                read_only_sql_transaction)a

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Tells the writer there is work (the journal calls it on append)."
  def wake(server \\ __MODULE__) do
    if pid = GenServer.whereis(server), do: send(pid, :work)
    :ok
  end

  @doc "Writes everything waiting, now. Returns `:ok`, or `{:error, reason}` if the database is away."
  @spec drain(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def drain(server \\ __MODULE__, timeout \\ 30_000), do: GenServer.call(server, :drain, timeout)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      journal: Keyword.get(opts, :journal, Journal),
      apply: Keyword.get(opts, :apply, &Ops.apply!/1),
      lease: Keyword.get(opts, :lease, Collector.lease_name()),
      shutdown_drain_ms: Keyword.get(opts, :shutdown_drain_ms, 15_000),
      backoff_ms: 1_000,
      timer: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_info(:work, state) do
    state = cancel(state)

    case write_batch(state) do
      :empty -> {:noreply, schedule(%{state | backoff_ms: 1_000}, @idle_ms)}
      {:ok, _n} -> {:noreply, schedule(%{state | backoff_ms: 1_000}, 0)}
      {:error, _} -> {:noreply, schedule(backoff(state), state.backoff_ms)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, drain_all(state, :infinity), state}
  end

  @impl true
  def terminate(_reason, state) do
    deadline = System.monotonic_time(:millisecond) + state.shutdown_drain_ms
    drain_all(state, deadline)
    :ok
  end

  defp drain_all(state, deadline) do
    if deadline != :infinity and System.monotonic_time(:millisecond) > deadline do
      {:error, :deadline}
    else
      case write_batch(state) do
        :empty -> :ok
        {:ok, _} -> drain_all(state, deadline)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- one batch ---------------------------------------------------------------

  defp write_batch(state) do
    case Journal.take(@batch, state.journal) do
      [] ->
        Status.put(:writer, %{ok_at: DateTime.utc_now(), error: nil})
        :empty

      entries ->
        journal_id = Journal.id(state.journal)

        case commit(entries, journal_id, state) do
          {:ok, applied, dropped} ->
            finish(entries, applied, dropped, state)

          {:error, :transient, reason} ->
            fail(reason)

          {:error, :permanent, _reason} ->
            one_by_one(entries, journal_id, state)
        end
    end
  end

  defp one_by_one(entries, journal_id, state) do
    Enum.reduce_while(entries, {:ok, 0}, fn {id, _, _, op} = entry, {:ok, n} ->
      case commit([entry], journal_id, state) do
        {:ok, applied, dropped} ->
          {:ok, _} = finish([entry], applied, dropped, state)
          {:cont, {:ok, n + 1}}

        {:error, :transient, reason} ->
          {:halt, fail(reason)}

        {:error, :permanent, reason} ->
          message = Exception.format_banner(:error, reason) |> String.slice(0, 2_000)
          Logger.error("collector write #{id} can't be applied, set aside: #{message}")

          if is_exception(reason),
            do: ErrorTracker.report(reason, [], %{op: inspect(op, limit: 20)})

          :ok = Journal.bury(id, message, state.journal)
          {:cont, {:ok, n}}
      end
    end)
  end

  defp commit(entries, journal_id, state) do
    Repo.transaction(
      fn ->
        last = mark(journal_id)
        todo = Enum.filter(entries, fn {id, _, _, _} -> id > last end)
        terms = terms(state.lease, todo)

        {applied, dropped} =
          Enum.reduce(todo, {0, 0}, fn {_id, epoch, made_at, op}, {a, d} ->
            if Lease.stale?(epoch, made_at, terms) do
              {a, d + 1}
            else
              state.apply.(op)
              {a + 1, d}
            end
          end)

        {max_id, _, _, _} = List.last(entries)
        set_mark(journal_id, max(max_id, last))
        {applied, dropped}
      end,
      timeout: 120_000
    )
    |> case do
      {:ok, {applied, dropped}} -> {:ok, applied, dropped}
      {:error, reason} -> {:error, :permanent, reason}
    end
  rescue
    error -> {:error, classify(error), error}
  catch
    :exit, reason -> {:error, :transient, reason}
  end

  defp finish(entries, applied, dropped, state) do
    {max_id, _, _, _} = List.last(entries)
    :ok = Journal.delete_through(max_id, state.journal)

    if dropped > 0,
      do: Logger.warning("dropped #{dropped} write(s) made by a superseded collector")

    Status.put(:writer, %{ok_at: DateTime.utc_now(), error: nil})
    {:ok, applied}
  end

  defp fail(reason) do
    message =
      case reason do
        %{__exception__: true} -> Exception.message(reason)
        other -> inspect(other)
      end

    Logger.warning("collector writes waiting: #{message}")
    Status.put(:writer, %{ok_at: Status.get(:writer)[:ok_at], error: message})
    {:error, reason}
  end

  defp classify(%DBConnection.ConnectionError{}), do: :transient
  defp classify(%Postgrex.Error{postgres: %{code: code}}) when code in @transient, do: :transient
  defp classify(%Postgrex.Error{postgres: nil}), do: :transient
  defp classify(_), do: :permanent

  defp mark(journal_id) do
    Repo.query!(
      "INSERT INTO collector_journal_marks (journal_id, last_op, updated_at) VALUES ($1, 0, now()) ON CONFLICT DO NOTHING",
      [journal_id]
    )

    Repo.query!(
      "SELECT last_op FROM collector_journal_marks WHERE journal_id = $1 FOR UPDATE",
      [journal_id]
    ).rows
    |> hd()
    |> hd()
  end

  defp set_mark(journal_id, id) do
    Repo.query!(
      "UPDATE collector_journal_marks SET last_op = $2, updated_at = now() WHERE journal_id = $1",
      [journal_id, id]
    )
  end

  # The terms that began after the oldest epoch in the batch.
  defp terms(_lease, []), do: []

  defp terms(lease, entries) do
    oldest =
      entries |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == 0)) |> Enum.min(fn -> nil end)

    if oldest do
      Repo.query!(
        "SELECT epoch, started_at FROM collector_terms WHERE name = $1 AND epoch > $2",
        [lease, oldest]
      ).rows
      |> Enum.map(&List.to_tuple/1)
    else
      []
    end
  end

  defp schedule(state, ms), do: %{state | timer: Process.send_after(self(), :work, ms)}

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp backoff(state), do: %{state | backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}
end
