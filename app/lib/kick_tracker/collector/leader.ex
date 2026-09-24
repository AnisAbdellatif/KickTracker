defmodule KickTracker.Collector.Leader do
  @moduledoc """
  Decides whether this node collects (project.md §10.1), by the rules in
  `Collector.Lease`, and starts or stops `Collector.Collection`
  accordingly.

  It holds the lease on a connection of its own (not the Repo's pool), as
  a Postgres advisory lock plus the `collector_lease` row:

    * **standing by**, it checks every second whether it may take over:
      within a second or two of the leader crashing, and within about 7s
      of it freezing or being cut off (it ends the silent leader's session);
    * **leading**, it heartbeats every second and checks it still holds the
      lock. Superseded (the epoch moved on) or having lost the lock to
      another node, it stops collecting at once. The database merely
      unreachable, it keeps collecting: the journal holds the writes, and
      no other node can take over meanwhile;
    * **a watchdog**: leading, if the viewers source hasn't completed a
      cycle for 5 minutes, the collection tree is restarted;
    * **the collection tree giving up** is restarted with a backoff (1s to
      60s), never taking the node down;
    * **on shutdown** it stops collecting, then releases the lease so a
      standby takes over within a second (a deploy's handoff).

  Job queues follow leadership: they run only on the leader.
  """

  use GenServer
  require Logger

  alias KickTracker.{Collector, Repo}
  alias KickTracker.Collector.{Collection, Lease, Status, Writer}

  @lock_class 4242
  @watchdog_s 300
  @max_restart_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 45_000}

  @doc "`:leader` or `:standby`."
  @spec role(GenServer.server()) :: :leader | :standby
  def role(server \\ __MODULE__), do: GenServer.call(server, :role)

  @doc "Runs one check now (tests)."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 15_000)

  @doc "The advisory lock key of a lease name."
  def lock_key(name), do: :erlang.phash2(name, 2_147_483_647)

  # --- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    lease = Keyword.get(opts, :lease, Collector.lease_name())
    conn_opts = Keyword.get(opts, :conn_opts, conn_opts())
    {:ok, conn} = Postgrex.start_link(conn_opts)

    state = %{
      conn_opts: conn_opts,
      me: Keyword.get(opts, :id, Collector.id()),
      lease: lease,
      key: lock_key(lease),
      conn: conn,
      role: :standby,
      epoch: nil,
      since: DateTime.utc_now(),
      free_since: nil,
      collection: nil,
      collection_started: nil,
      restart_ms: 1_000,
      standby_ms: Keyword.get(opts, :standby_ms, 1_000),
      leader_ms: Keyword.get(opts, :leader_ms, 1_000),
      limits: Keyword.get(opts, :limits, %{}),
      auto: Keyword.get(opts, :auto, true),
      publish: Keyword.get(opts, :publish, true),
      # Tests replace these; the defaults are plain calls (`hook/3`), so a
      # code reload never leaves a stale function in the state.
      hooks: Map.new(~w(start stop elected queues healthy?)a, &{&1, Keyword.get(opts, &1)})
    }

    # A collection tree left by an earlier incarnation of this process (it
    # crashed without stopping it) must not run on unsupervised: stopped
    # here, and started again only if this node leads.
    if state.hooks.start == nil, do: stop_orphans()
    if state.publish, do: Collector.put_leadership(false, nil)
    Status.merge(:leader, %{role: :standby, since: state.since, id: state.me})
    if state.auto, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:role, _from, state), do: {:reply, state.role, state}
  def handle_call(:tick, _from, state), do: {:reply, :ok, check(state)}

  @impl true
  def handle_info(:tick, state) do
    state = check(state)
    ms = if state.role == :leader, do: state.leader_ms, else: state.standby_ms
    Process.send_after(self(), :tick, ms)
    {:noreply, state}
  end

  def handle_info(:restart_collection, %{role: :leader, collection: nil} = state),
    do: {:noreply, begin_collection(state)}

  def handle_info(:restart_collection, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{collection: pid} = state) do
    Logger.error(
      "collection stopped (#{inspect(reason, limit: 5)}); restarting in #{state.restart_ms}ms"
    )

    Process.send_after(self(), :restart_collection, state.restart_ms)

    # Back off only if it keeps failing soon after starting.
    ran_s = DateTime.diff(DateTime.utc_now(), state.collection_started || DateTime.utc_now())
    next = if ran_s > 300, do: 1_000, else: min(state.restart_ms * 2, @max_restart_ms)
    {:noreply, %{state | collection: nil, restart_ms: next}}
  end

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    Logger.warning("lease connection exited (#{inspect(reason, limit: 5)}); reconnecting")
    {:ok, conn} = Postgrex.start_link(state.conn_opts)
    {:noreply, %{state | conn: conn}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{role: :leader} = state) do
    stop(state)

    q(
      state,
      "UPDATE collector_lease SET released_at = now(), heartbeat_at = now() WHERE name = $1 AND epoch = $2 AND holder = $3",
      [
        state.lease,
        state.epoch,
        state.me
      ]
    )

    end_term(state, state.epoch, "released")
    q(state, "SELECT pg_advisory_unlock($1::int, $2::int)", [@lock_class, state.key])
    Logger.warning("collector #{state.me}: released the lease (epoch #{state.epoch})")
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- checks ------------------------------------------------------------------

  defp check(%{role: :standby} = state) do
    now = DateTime.utc_now()
    Status.put(:leader_loop_at, now)
    hook(state, :queues, [:pause])

    with {:ok, lease, db} <- read_lease(state),
         {:ok, free?} <- lock_free?(state) do
      free_since = if free?, do: state.free_since || db.now
      state = %{state | free_since: free_since}

      obs = %{
        now: db.now,
        lock_free?: free?,
        free_since: free_since,
        db_started_at: db.started_at
      }

      case Lease.decide(lease, state.me, obs, state.limits) do
        :acquire ->
          try_acquire(state, lease, obs)

        :terminate ->
          end_silent_session(state, lease)

        :wait ->
          state
      end
    else
      {:error, _} -> %{state | free_since: nil}
    end
  end

  defp check(%{role: :leader} = state) do
    now = DateTime.utc_now()
    Status.put(:leader_loop_at, now)

    result =
      q(
        state,
        """
        WITH hb AS (
          UPDATE collector_lease SET heartbeat_at = now()
          WHERE name = $1 AND epoch = $2 AND holder = $3 RETURNING 1
        )
        SELECT (SELECT count(*) FROM hb),
               EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory'
                       AND classid = $4::int::oid AND objid = $5::int::oid AND objsubid = 2
                       AND pid = pg_backend_pid() AND granted)
        """,
        [state.lease, state.epoch, state.me, @lock_class, state.key]
      )

    state =
      case result do
        {:ok, %{rows: [[1, true]]}} ->
          verified(state, now)

        # The connection was reset (the database restarted): take the lock
        # again, unless someone else has it.
        {:ok, %{rows: [[1, false]]}} ->
          case q(state, "SELECT pg_try_advisory_lock($1::int, $2::int)", [@lock_class, state.key]) do
            {:ok, %{rows: [[true]]}} -> verified(state, now)
            {:ok, _} -> step_down(state, "another collector holds the lock")
            {:error, _} -> state
          end

        {:ok, %{rows: [[0, _]]}} ->
          step_down(state, "superseded by another collector")

        # Unreachable: keep collecting into the journal.
        {:error, _} ->
          Status.merge(:leader, %{verified: false})
          state
      end

    if state.role == :leader, do: watchdog(state, now), else: state
  end

  # The holder holds the lock but has stopped heartbeating: frozen, or cut
  # off with a half-open connection. Its session is ended so the lock
  # frees; the holder, if it comes back, finds itself superseded.
  defp end_silent_session(state, lease) do
    Logger.warning(
      "collector #{state.me}: #{lease.holder} holds the lease but is silent; ending its session"
    )

    q(
      state,
      "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND database = (SELECT oid FROM pg_database WHERE datname = current_database()) AND classid = $1::int::oid AND objid = $2::int::oid AND objsubid = 2 AND granted",
      [@lock_class, state.key]
    )

    state
  end

  defp verified(state, now) do
    Status.merge(:leader, %{verified: true, verified_at: now})
    hook(state, :queues, [:run])
    state
  end

  defp watchdog(state, now) do
    if (state.collection && DateTime.diff(now, state.collection_started) > @watchdog_s) and
         not hook(state, :healthy?, [now]) do
      Logger.error(
        "collector #{state.me}: no viewers cycle for #{@watchdog_s}s, restarting collection"
      )

      state = stop(state)
      begin_collection(state)
    else
      state
    end
  end

  # --- taking and giving up the lease -----------------------------------------------

  defp try_acquire(state, lease, obs) do
    case q(state, "SELECT pg_try_advisory_lock($1::int, $2::int)", [@lock_class, state.key]) do
      {:ok, %{rows: [[true]]}} ->
        silent_s = lease.heartbeat_at && DateTime.diff(obs.now, lease.heartbeat_at)
        limits = Map.merge(Lease.defaults(), state.limits)

        reason =
          cond do
            lease.holder == nil -> nil
            lease.holder == state.me -> "restarted"
            lease.released_at -> "released"
            silent_s && silent_s > limits.unresponsive_s -> "unresponsive"
            true -> "stopped"
          end

        result =
          Postgrex.transaction(
            state.conn,
            fn c ->
              end_term(c, state.lease, lease.epoch, reason)

              %{rows: [[epoch, at]]} =
                Postgrex.query!(
                  c,
                  "UPDATE collector_lease SET epoch = epoch + 1, holder = $2, acquired_at = now(), heartbeat_at = now(), released_at = NULL WHERE name = $1 RETURNING epoch, acquired_at",
                  [state.lease, state.me]
                )

              Postgrex.query!(
                c,
                "INSERT INTO collector_terms (name, epoch, holder, started_at) VALUES ($1, $2, $3, $4)",
                [state.lease, epoch, state.me, at]
              )

              epoch
            end,
            timeout: 5_000
          )

        case result do
          {:ok, epoch} ->
            become_leader(state, epoch)

          {:error, reason} ->
            Logger.warning("could not record the lease: #{inspect(reason)}")
            q(state, "SELECT pg_advisory_unlock($1::int, $2::int)", [@lock_class, state.key])
            state
        end

      _ ->
        state
    end
  rescue
    error ->
      Logger.warning("could not take the lease: #{Exception.message(error)}")
      state
  end

  defp become_leader(state, epoch) do
    now = DateTime.utc_now()
    Logger.warning("collector #{state.me}: collecting (epoch #{epoch})")
    if state.publish, do: Collector.put_leadership(true, epoch)
    Status.merge(:leader, %{role: :leader, epoch: epoch, since: now, verified: true})
    hook(state, :elected, [epoch])
    hook(state, :queues, [:run])
    begin_collection(%{state | role: :leader, epoch: epoch, since: now, free_since: nil})
  end

  defp step_down(state, why) do
    Logger.warning("collector #{state.me}: no longer collecting (#{why})")
    state = stop(state)
    hook(state, :queues, [:pause])
    q(state, "SELECT pg_advisory_unlock($1::int, $2::int)", [@lock_class, state.key])
    if state.publish, do: Collector.put_leadership(false, nil)
    now = DateTime.utc_now()
    Status.merge(:leader, %{role: :standby, since: now})
    %{state | role: :standby, since: now, free_since: nil, restart_ms: 1_000}
  end

  defp begin_collection(state) do
    case hook(state, :start, []) do
      {:ok, pid} ->
        Process.monitor(pid)
        %{state | collection: pid, collection_started: DateTime.utc_now()}

      other ->
        Logger.error("could not start collection: #{inspect(other, limit: 5)}")
        Process.send_after(self(), :restart_collection, state.restart_ms)
        %{state | restart_ms: min(state.restart_ms * 2, @max_restart_ms)}
    end
  end

  defp stop(%{collection: nil} = state), do: state

  defp stop(state) do
    hook(state, :stop, [state.collection])
    %{state | collection: nil}
  end

  defp end_term(%{} = state, epoch, reason) when is_map_key(state, :conn),
    do:
      q(
        state,
        "UPDATE collector_terms SET ended_at = now(), end_reason = $3 WHERE name = $1 AND epoch = $2 AND ended_at IS NULL",
        [state.lease, epoch, reason]
      )

  defp end_term(conn, lease, epoch, reason) do
    Postgrex.query!(
      conn,
      "UPDATE collector_terms SET ended_at = now(), end_reason = $3 WHERE name = $1 AND epoch = $2 AND ended_at IS NULL",
      [lease, epoch, reason]
    )
  end

  # --- the lease row and lock ----------------------------------------------------

  defp read_lease(state) do
    with {:ok, _} <-
           q(state, "INSERT INTO collector_lease (name) VALUES ($1) ON CONFLICT DO NOTHING", [
             state.lease
           ]),
         {:ok, %{rows: [[epoch, holder, heartbeat_at, released_at, now, started_at]]}} <-
           q(
             state,
             "SELECT epoch, holder, heartbeat_at, released_at, now(), pg_postmaster_start_time() FROM collector_lease WHERE name = $1",
             [state.lease]
           ) do
      {:ok, %{epoch: epoch, holder: holder, heartbeat_at: heartbeat_at, released_at: released_at},
       %{now: now, started_at: started_at}}
    else
      {:ok, _} -> {:error, :no_lease}
      error -> error
    end
  end

  # Advisory locks belong to a database, but pg_locks lists the whole
  # server's: every query on it is scoped to ours, or a deployment sharing
  # the server (a shadow, a staging copy) would see, and end, our lock.
  defp lock_free?(state) do
    case q(
           state,
           "SELECT NOT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND database = (SELECT oid FROM pg_database WHERE datname = current_database()) AND classid = $1::int::oid AND objid = $2::int::oid AND objsubid = 2 AND granted)",
           [@lock_class, state.key]
         ) do
      {:ok, %{rows: [[free?]]}} -> {:ok, free?}
      error -> error
    end
  end

  defp q(state, sql, params) do
    Postgrex.query(state.conn, sql, params, timeout: 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  # The Repo's connection settings, for a connection of our own: session
  # state (the advisory lock) must live on one connection we control.
  defp conn_opts do
    Repo.config()
    |> Keyword.take(
      ~w(hostname port username password database ssl ssl_opts socket_dir socket parameters connect_timeout socket_options)a
    )
    |> Keyword.merge(
      pool_size: 1,
      backoff_type: :exp,
      backoff_min: 500,
      backoff_max: 5_000,
      show_sensitive_data_on_connection_error: false
    )
  end

  # --- hooks -----------------------------------------------------------------------

  defp hook(state, name, args) do
    case state.hooks[name] do
      nil -> apply(default_hook(name), args)
      fun -> apply(fun, args)
    end
  end

  defp default_hook(:start), do: &start_collection/0
  defp default_hook(:stop), do: &stop_collection/1
  defp default_hook(:elected), do: &elected/1
  defp default_hook(:queues), do: &queues/1
  defp default_hook(:healthy?), do: &collecting?/1

  defp stop_orphans do
    if Process.whereis(Collector.Slot) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Collector.Slot), is_pid(pid) do
        Logger.warning("stopping a collection left by an earlier leader process")
        DynamicSupervisor.terminate_child(Collector.Slot, pid)
      end
    end

    :ok
  end

  defp start_collection,
    do: DynamicSupervisor.start_child(Collector.Slot, {Collection, []})

  defp stop_collection(pid), do: DynamicSupervisor.terminate_child(Collector.Slot, pid)

  # Before collecting, write what this node's journal still holds (from an
  # earlier term), so the channel processes start from an up-to-date
  # database. Bounded: a database that is away doesn't delay collection.
  defp elected(_epoch) do
    if GenServer.whereis(Writer) do
      task = Task.async(fn -> Writer.drain(Writer, 10_000) end)
      Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # Job queues run only where collection runs.
  defp queues(want) do
    for {queue, _} <- Application.get_env(:kick_tracker, Oban)[:queues] || [] do
      case Oban.check_queue(queue: queue) do
        %{paused: true} when want == :run -> Oban.resume_queue(queue: queue, local_only: true)
        %{paused: false} when want == :pause -> Oban.pause_queue(queue: queue, local_only: true)
        _ -> :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp collecting?(now) do
    case Status.get({:source, :viewers}) do
      %{cycle_at: at} -> DateTime.diff(now, at) < @watchdog_s
      _ -> false
    end
  end
end
