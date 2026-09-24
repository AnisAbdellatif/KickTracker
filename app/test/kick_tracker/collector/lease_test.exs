defmodule KickTracker.Collector.LeaseTest do
  @moduledoc "Who may collect, and which writes a superseded collector may still make."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Collector.Lease

  @now ~U[2026-09-01 12:00:00Z]
  defp ago(s), do: DateTime.add(@now, -s)

  describe "decide/3" do
    # The database has been up for an hour.
    defp obs(attrs),
      do:
        Map.merge(
          %{now: @now, lock_free?: false, free_since: nil, db_started_at: ago(3600)},
          Map.new(attrs)
        )

    defp lease(attrs),
      do:
        Map.merge(
          %{epoch: 3, holder: "b", heartbeat_at: ago(1), released_at: nil},
          Map.new(attrs)
        )

    test "a lease nobody holds, released, or last held by this node is taken when the lock is free" do
      assert Lease.decide(nil, "a", obs(lock_free?: true)) == :acquire
      assert Lease.decide(lease(holder: nil), "a", obs(lock_free?: true)) == :acquire
      assert Lease.decide(lease(released_at: @now), "a", obs(lock_free?: true)) == :acquire
      assert Lease.decide(lease(holder: "a"), "a", obs(lock_free?: true)) == :acquire
      # Released but the lock not let go yet (a millisecond): wait.
      assert Lease.decide(lease(released_at: @now), "a", obs([])) == :wait
    end

    test "a live leader keeps it" do
      assert Lease.decide(lease([]), "a", obs([])) == :wait
    end

    test "a crashed leader (its session ended, the database didn't restart) is replaced at once" do
      assert Lease.decide(lease([]), "a", obs(lock_free?: true, free_since: @now)) == :acquire
    end

    test "after a database restart the leader gets time to take its lock back" do
      restarted = obs(lock_free?: true, free_since: @now, db_started_at: ago(0))
      assert Lease.decide(lease(heartbeat_at: ago(2)), "a", restarted) == :wait

      # Still silent past the grace, and the lock confirmed free: take it.
      gone = %{restarted | free_since: ago(5)}
      assert Lease.decide(lease(heartbeat_at: ago(11)), "a", gone) == :acquire
      assert Lease.decide(lease(heartbeat_at: ago(11)), "a", restarted) == :wait
    end

    test "a leader holding the lock but silent (frozen, cut off) has its session ended" do
      assert Lease.decide(lease(heartbeat_at: ago(7)), "a", obs([])) == :terminate
      assert Lease.decide(lease(heartbeat_at: ago(3)), "a", obs([])) == :wait
      # Thresholds can be set.
      assert Lease.decide(lease(heartbeat_at: ago(3)), "a", obs([]), %{unresponsive_s: 2}) ==
               :terminate
    end
  end

  describe "stale?/3" do
    test "a write is dropped only if made after a newer holder started" do
      terms = [{4, ago(100)}, {5, ago(10)}]

      refute Lease.stale?(5, @now, terms)
      # Made by holder 4 before 5 took over: legitimate, kept.
      refute Lease.stale?(4, ago(20), terms)
      # Made by holder 4 after 5 took over: the overlap, dropped.
      assert Lease.stale?(4, ago(5), terms)
      assert Lease.stale?(3, ago(50), terms)
      # Not made under a lease.
      refute Lease.stale?(0, @now, terms)
    end

    property "only writes at or after the next term's start are dropped" do
      check all(
              epoch <- integer(1..10),
              gaps <- list_of(integer(1..100), length: 10),
              offset <- integer(-2_000..2_000)
            ) do
        terms =
          gaps
          |> Enum.scan(&(&1 + &2))
          |> Enum.with_index(1)
          |> Enum.map(fn {s, e} -> {e, DateTime.add(@now, s)} end)

        made_at = DateTime.add(@now, offset)
        next = Enum.find(terms, fn {e, _} -> e == epoch + 1 end)

        expected = next != nil and not DateTime.before?(made_at, elem(next, 1))
        assert Lease.stale?(epoch, made_at, terms) == expected
      end
    end
  end
end
