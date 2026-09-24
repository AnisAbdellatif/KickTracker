defmodule KickTracker.Metrics.OutliersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Metrics
  alias KickTracker.Metrics.Outliers

  @t0 ~U[2026-03-02 20:00:00Z]
  defp series(values),
    do: values |> Enum.with_index() |> Enum.map(fn {v, i} -> {DateTime.add(@t0, i * 60), v} end)

  defp at(i), do: DateTime.add(@t0, i * 60)

  test "a sudden 0 mid-stream and a one-reading spike are flagged" do
    assert Outliers.flags(series([500, 510, 0, 505, 498])) == [{at(2), :zero}]
    assert Outliers.flags(series([500, 510, 9000, 505, 498])) == [{at(2), :spike}]
  end

  test "real movements are not glitches" do
    # A stream ending, a raid arriving and staying, a small channel's zero.
    assert Outliers.flags(series([500, 400, 0, 0, 0])) == []
    assert Outliers.flags(series([500, 510, 3000, 3100, 3050])) == []
    assert Outliers.flags(series([3, 0, 4])) == []
    # Nothing to compare at the edges or across a gap.
    assert Outliers.flags(series([9000, 500, 510])) == []
    assert Outliers.flags([{at(0), 500}, {at(1), 0}, {at(10), 500}]) == []
  end

  test "before and after on the same input: the peak no longer comes from the glitch" do
    samples = series([500, 510, 9000, 505, 498])
    # Before: the one bad reading was the stream's peak.
    assert Metrics.viewers(samples).peak == 9000
    # After: flagged, it counts in the average but isn't the peak.
    flagged = samples |> Outliers.flags() |> MapSet.new(&elem(&1, 0))
    after_ = Metrics.viewers(samples, flagged)
    assert after_.peak == 510
    assert after_.avg == Metrics.viewers(samples).avg
  end

  property "a steady series has no flags, and flags never touch the first or last reading" do
    check all(values <- list_of(integer(0..20_000), min_length: 3, max_length: 60)) do
      flags = Outliers.flags(series(values))
      flagged = MapSet.new(flags, &elem(&1, 0))
      refute MapSet.member?(flagged, at(0))
      refute MapSet.member?(flagged, at(length(values) - 1))
      # Order doesn't matter.
      assert Outliers.flags(Enum.shuffle(series(values))) == flags
    end

    check all(v <- integer(1..50_000), n <- integer(3..30)) do
      assert Outliers.flags(series(List.duplicate(v, n))) == []
    end
  end
end
