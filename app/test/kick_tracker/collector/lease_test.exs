defmodule KickTracker.Collector.LeaseTest do
  @moduledoc "Who may collect, and which writes a superseded collector may still make."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Collector.Lease

  @now ~U[2026-09-01 12:00:00Z]
  defp ago(s), do: DateTime.add(@now, -s)

  describe "may_acquire?/4" do
    test "a lease nobody holds, or held by this node, is taken at once" do
      assert Lease.may_acquire?(nil, "a", @now, nil)

      assert Lease.may_acquire?(
               %{holder: nil, heartbeat_at: nil, released_at: nil, epoch: 0},
               "a",
               @now,
               nil
             )

      assert Lease.may_acquire?(
               %{holder: "a", heartbeat_at: @now, released_at: nil, epoch: 3},
               "a",
               @now,
               nil
             )
    end

    test "a released lease is taken at once (a deploy's handoff)" do
      lease = %{holder: "b", heartbeat_at: @now, released_at: @now, epoch: 3}
      assert Lease.may_acquire?(lease, "a", @now, @now)
    end

    test "a live holder keeps it; a silent one loses it once the lock is confirmed free" do
      live = %{holder: "b", heartbeat_at: ago(5), released_at: nil, epoch: 3}
      refute Lease.may_acquire?(live, "a", @now, ago(60))

      silent = %{live | heartbeat_at: ago(Lease.stale_s() + 1)}
      # Just seen free: the holder may only have blipped.
      refute Lease.may_acquire?(silent, "a", @now, @now)
      refute Lease.may_acquire?(silent, "a", @now, nil)
      assert Lease.may_acquire?(silent, "a", @now, ago(5))
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
