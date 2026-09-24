defmodule KickTracker.Metrics.CoverageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Metrics.Coverage

  doctest Coverage

  @t0 ~U[2026-01-01 00:00:00Z]
  defp at(s), do: DateTime.add(@t0, s)
  defp p(from, to, ok \\ true), do: %{from_at: at(from), to_at: at(to), ok: ok}

  test "a period covers its outcomes plus one cadence, clipped to the window" do
    # Outcomes every 60s from 0 to 540: covers 0..600.
    assert Coverage.fraction([p(0, 540)], at(0), at(600), 60) == 1.0
    assert Coverage.fraction([p(0, 540)], at(0), at(1200), 60) == 0.5
    # Starts before the window.
    assert Coverage.fraction([p(-600, 240)], at(0), at(600), 60) == 0.5
  end

  test "failed periods cover nothing; overlaps count once" do
    assert Coverage.fraction([p(0, 540, false)], at(0), at(600), 60) == 0.0
    assert Coverage.fraction([p(0, 240), p(120, 240), p(0, 60)], at(0), at(600), 60) == 0.5
  end

  defp secs(gaps),
    do: Enum.map(gaps, fn {a, b} -> {DateTime.diff(a, @t0), DateTime.diff(b, @t0)} end)

  test "gaps are what no ok period covers" do
    assert secs(Coverage.gaps([p(60, 120), p(300, 340, false)], at(0), at(600), 60)) ==
             [{0, 60}, {180, 600}]

    assert secs(Coverage.gaps([], at(0), at(10), 60)) == [{0, 10}]
    assert Coverage.gaps([p(0, 600)], at(0), at(600), 60) == []
  end

  property "covered time and gaps add up to the window, whatever the periods" do
    period =
      gen all(a <- integer(-500..4000), len <- integer(0..900), ok <- boolean()) do
        p(a, a + len, ok)
      end

    check all(periods <- list_of(period, max_length: 12), pad <- integer(0..120)) do
      window = 3600
      f = Coverage.fraction(periods, at(0), at(window), pad)

      gap_s =
        Coverage.gaps(periods, at(0), at(window), pad)
        |> Enum.map(fn {a, b} -> DateTime.diff(b, a, :millisecond) end)
        |> Enum.sum()

      assert f >= 0.0 and f <= 1.0
      assert_in_delta f * window * 1000 + gap_s, window * 1000, 1
      # Order of periods doesn't matter.
      assert Coverage.fraction(Enum.shuffle(periods), at(0), at(window), pad) == f
    end
  end
end
