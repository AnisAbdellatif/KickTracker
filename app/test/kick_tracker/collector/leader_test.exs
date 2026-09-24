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
  defp collector(id, lease) do
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
        healthy?: fn _ -> true end
      )

    Process.unlink(pid)
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
end
