defmodule KickTracker.Collector.LeaderTest do
  @moduledoc """
  Two collectors contending for one lease, on their own real database
  connections (the lease is session state, outside the test sandbox): one
  collects, the other stands by; a clean handoff takes a second; a
  superseded leader stops at once; every term is recorded.
  """

  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias KickTracker.Collector.Leader

  setup do
    lease = "test-#{System.unique_integer([:positive])}"
    {:ok, conn} = Postgrex.start_link(conn_opts())

    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(conn_opts())
      Postgrex.query!(c, "DELETE FROM collector_terms WHERE name = $1", [lease])
      Postgrex.query!(c, "DELETE FROM collector_lease WHERE name = $1", [lease])
    end)

    %{lease: lease, conn: conn}
  end

  defp conn_opts do
    KickTracker.Repo.config()
    |> Keyword.take(~w(hostname port username password database)a)
    |> Keyword.put(:pool_size, 1)
  end

  # A collector whose "collection" is a process that tells the test it runs.
  defp collector(id, lease, limits \\ %{}) do
    test = self()

    start = fn ->
      pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test, {:collecting, id, pid})
      {:ok, pid}
    end

    stop = fn pid ->
      send(pid, :stop)
      send(test, {:stopped, id})
      :ok
    end

    {:ok, pid} =
      Leader.start_link(
        name: :"leader_#{id}",
        id: id,
        lease: lease,
        auto: false,
        publish: false,
        start: start,
        stop: stop,
        elected: fn _ -> :ok end,
        queues: fn _ -> :ok end,
        healthy?: fn _ -> true end,
        limits: limits
      )

    Process.unlink(pid)
    # Stopped even when the test fails, or the name stays taken for the next.
    on_exit(fn ->
      if Process.alive?(pid), do: catch_exit(GenServer.stop(pid, :shutdown))
    end)

    pid
  end

  defp terms(conn, lease) do
    Postgrex.query!(
      conn,
      "SELECT epoch, holder, end_reason FROM collector_terms WHERE name = $1 ORDER BY epoch",
      [lease]
    ).rows
  end

  test "one collects, the other stands by; a clean shutdown hands over at once",
       %{lease: lease, conn: conn} do
    a = collector("a", lease)
    b = collector("b", lease)

    :ok = Leader.tick(a)
    :ok = Leader.tick(b)
    assert Leader.role(a) == :leader
    assert Leader.role(b) == :standby
    assert_receive {:collecting, "a", _}
    refute_receive {:collecting, "b", _}, 50

    # A deploy: a stops (and releases), b takes over on its next check.
    GenServer.stop(a, :shutdown)
    assert_receive {:stopped, "a"}
    :ok = Leader.tick(b)
    assert Leader.role(b) == :leader
    assert_receive {:collecting, "b", _}

    assert terms(conn, lease) == [[1, "a", "released"], [2, "b", nil]]
    GenServer.stop(b, :shutdown)
  end

  test "a leader that finds itself superseded stops collecting at once", %{
    lease: lease,
    conn: conn
  } do
    a = collector("a", lease)
    :ok = Leader.tick(a)
    assert_receive {:collecting, "a", _}

    # Another holder recorded (as after a takeover the leader missed).
    Postgrex.query!(
      conn,
      "UPDATE collector_lease SET epoch = epoch + 1, holder = 'z' WHERE name = $1",
      [
        lease
      ]
    )

    :ok = Leader.tick(a)
    assert Leader.role(a) == :standby
    assert_receive {:stopped, "a"}
    GenServer.stop(a, :shutdown)
  end

  test "a standby doesn't take over from a live leader", %{lease: lease} do
    a = collector("a", lease)
    b = collector("b", lease)
    :ok = Leader.tick(a)

    for _ <- 1..3 do
      :ok = Leader.tick(a)
      :ok = Leader.tick(b)
    end

    assert Leader.role(a) == :leader
    assert Leader.role(b) == :standby
    GenServer.stop(b, :shutdown)
    GenServer.stop(a, :shutdown)
  end

  test "a collector restarting takes its own lease back at once", %{lease: lease, conn: conn} do
    a = collector("a", lease)
    :ok = Leader.tick(a)
    assert_receive {:collecting, "a", _}

    # Killed: no release. Its lock goes with its connection.
    Process.exit(a, :kill)

    Stream.repeatedly(fn -> Process.sleep(20) end)
    |> Enum.find(fn _ ->
      Postgrex.query!(
        conn,
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $1::int::oid",
        [Leader.lock_key(lease)]
      ).rows == [[0]]
    end)

    a2 = collector("a", lease)
    :ok = Leader.tick(a2)
    assert Leader.role(a2) == :leader
    assert [[1, "a", "restarted"], [2, "a", nil]] = terms(conn, lease)
    GenServer.stop(a2, :shutdown)
  end

  test "a crashed leader is replaced on the standby's next check, not after a timeout", %{
    lease: lease,
    conn: conn
  } do
    a = collector("a", lease)
    b = collector("b", lease)
    :ok = Leader.tick(a)
    assert_receive {:collecting, "a", _}

    # Killed: no release; its lock goes with its connection.
    Process.exit(a, :kill)
    wait_lock_free(conn, lease)

    :ok = Leader.tick(b)
    assert Leader.role(b) == :leader
    assert [[1, "a", "stopped"], [2, "b", nil]] = terms(conn, lease)
    GenServer.stop(b, :shutdown)
  end

  test "a frozen leader holding the lock has its session ended and is replaced", %{
    lease: lease,
    conn: conn
  } do
    a = collector("a", lease, %{unresponsive_s: 1})
    b = collector("b", lease, %{unresponsive_s: 1})
    :ok = Leader.tick(a)
    assert_receive {:collecting, "a", _}

    # Frozen: alive, its connection open and holding the lock, silent.
    :sys.suspend(a)
    Process.sleep(2_100)

    :ok = Leader.tick(b)
    wait_lock_free(conn, lease)
    :ok = Leader.tick(b)
    assert Leader.role(b) == :leader
    assert [[1, "a", "unresponsive"], [2, "b", nil]] = terms(conn, lease)

    # Back: it finds itself superseded and stops as soon as it reaches the
    # database again (its connection was ended; until it reconnects, it
    # can't tell that from the database being unreachable, and keeps on).
    :sys.resume(a)
    assert tick_until(a, :standby)
    assert_receive {:stopped, "a"}
    GenServer.stop(a, :shutdown)
    GenServer.stop(b, :shutdown)
  end

  defp tick_until(server, role, tries \\ 50) do
    :ok = Leader.tick(server)

    cond do
      Leader.role(server) == role ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(100)
        tick_until(server, role, tries - 1)
    end
  end

  defp wait_lock_free(conn, lease) do
    Stream.repeatedly(fn -> Process.sleep(20) end)
    |> Enum.find(fn _ ->
      Postgrex.query!(
        conn,
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $1::int::oid",
        [Leader.lock_key(lease)]
      ).rows == [[0]]
    end)
  end

  test "a leader process starting stops a collection an earlier one left running", %{
    lease: lease
  } do
    start_supervised!({DynamicSupervisor, name: KickTracker.Collector.Slot})

    {:ok, orphan} =
      DynamicSupervisor.start_child(KickTracker.Collector.Slot, {Agent, fn -> :collecting end})

    {:ok, leader} =
      Leader.start_link(name: :leader_orphan, id: "o", lease: lease, auto: false, publish: false)

    Process.unlink(leader)
    refute Process.alive?(orphan)
    GenServer.stop(leader, :shutdown)
  end

  test "a collector of another database on the same server (a shadow, a staging copy) is left alone",
       %{lease: lease, conn: conn} do
    a = collector("a", lease)
    :ok = Leader.tick(a)
    assert_receive {:collecting, "a", _}

    other_db =
      KickTracker.OtherRepo.config()
      |> Keyword.take(~w(hostname port username password database)a)
      |> Keyword.put(:pool_size, 1)

    {:ok, other} =
      Leader.start_link(
        name: :leader_other_db,
        id: "shadow",
        lease: lease,
        auto: false,
        publish: false,
        conn_opts: other_db,
        start: fn -> {:ok, spawn(fn -> receive(do: (:stop -> :ok)) end)} end,
        stop: fn pid -> send(pid, :stop) end,
        elected: fn _ -> :ok end,
        queues: fn _ -> :ok end,
        healthy?: fn _ -> true end
      )

    holder = fn ->
      Postgrex.query!(
        conn,
        "SELECT pid FROM pg_locks WHERE locktype = 'advisory' AND objid = $1::int::oid AND database = (SELECT oid FROM pg_database WHERE datname = current_database())",
        [Leader.lock_key(lease)]
      ).rows
    end

    before = holder.()
    Process.unlink(other)
    :ok = Leader.tick(other)
    :ok = Leader.tick(other)
    # Each leads in its own database; our leader's session wasn't ended.
    assert Leader.role(other) == :leader
    assert holder.() == before
    :ok = Leader.tick(a)
    assert Leader.role(a) == :leader

    GenServer.stop(other, :shutdown)
    {:ok, c} = Postgrex.start_link(other_db)
    Postgrex.query!(c, "DELETE FROM collector_terms WHERE name = $1", [lease])
    Postgrex.query!(c, "DELETE FROM collector_lease WHERE name = $1", [lease])
    GenServer.stop(a, :shutdown)
  end
end
