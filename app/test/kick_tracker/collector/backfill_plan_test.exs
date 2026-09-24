defmodule KickTracker.Collector.BackfillPlanTest do
  @moduledoc "Which ranges the shadow fills: what it covered and we didn't, and nothing else."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Collector.BackfillPlan

  @t0 ~U[2026-09-01 12:00:00Z]
  defp t(s), do: DateTime.add(@t0, s)
  defp r(a, b), do: {t(a), t(b)}

  test "an outage we had and the shadow didn't is filled; a late poll isn't" do
    window = r(0, 3600)
    # We polled until 600, then nothing until 1500 (a VPS outage), and a
    # poll 70s late at 2000.
    ours = [r(0, 600), r(1500, 1930), r(2000, 3600)]
    shadow = [r(0, 3600)]

    assert BackfillPlan.fill(window, ours, shadow, 60, 60) == [r(660, 1500)]
  end

  test "nothing is filled where the shadow wasn't collecting either" do
    ours = [r(0, 600)]
    shadow = [r(0, 300), r(2000, 2400)]
    assert BackfillPlan.fill(r(0, 3600), ours, shadow, 60, 60) == [r(2000, 2460)]
  end

  test "the window bounds it" do
    assert BackfillPlan.fill(r(100, 200), [], [r(0, 3600)], 60, 10) == [r(100, 200)]
  end

  property "fills are inside the shadow's coverage and outside ours" do
    ranges =
      list_of(
        bind(integer(0..3000), fn a -> map(integer(1..600), fn len -> r(a, a + len) end) end),
        max_length: 6
      )

    check all(ours <- ranges, shadow <- ranges) do
      pad = 60
      fills = BackfillPlan.fill(r(0, 4000), ours, shadow, pad, 1)

      covered = fn periods, at ->
        Enum.any?(periods, fn {a, b} ->
          not DateTime.before?(at, a) and DateTime.before?(at, DateTime.add(b, pad))
        end)
      end

      for {a, b} <- fills, s <- [0, DateTime.diff(b, a) - 1] do
        at = DateTime.add(a, s)
        assert covered.(shadow, at)
        refute covered.(ours, at)
      end
    end
  end
end
