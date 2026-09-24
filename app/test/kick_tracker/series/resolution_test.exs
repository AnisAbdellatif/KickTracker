defmodule KickTracker.Series.ResolutionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Series.Resolution

  doctest Resolution

  @t0 ~U[2026-01-01 00:00:00Z]

  test "a requested resolution is honoured only when it gives fewer points" do
    a_day_later = DateTime.add(@t0, 1, :day)
    assert Resolution.choose(@t0, a_day_later) == :m5
    assert Resolution.choose(@t0, a_day_later, :hour) == :hour
    assert Resolution.choose(@t0, a_day_later, :raw) == :m5
    assert Resolution.parse("1h") == :hour and Resolution.parse("bogus") == nil
  end

  # Daily buckets pass 2 000 points after five and a half years of
  # history; weekly buckets will be needed then (project.md §13.4).
  test "no series over about 2 000 points, for up to five years" do
    for days <- [0.5, 1, 7, 30, 90, 365, 5 * 365] do
      to = DateTime.add(@t0, round(days * 86_400))

      points =
        case Resolution.choose(@t0, to) do
          :raw -> div(DateTime.diff(to, @t0), 60)
          :day -> round(days)
          res -> length(Resolution.grid(@t0, to, res))
        end

      assert points <= 2_200, "#{days} days gave #{points} points"
    end
  end

  test "the grid is aligned to the bucket and ends before `to`" do
    from = DateTime.add(@t0, 90)
    to = DateTime.add(@t0, 900)

    assert Resolution.grid(from, to, :m5) ==
             Enum.map([0, 300, 600], &(&1 + DateTime.to_unix(@t0)))

    assert Resolution.grid(to, from, :m5) == []
  end

  test "fill leaves empty buckets nil, never 0" do
    assert Resolution.fill([0, 300, 600], [{300, 5, 9}], 2) == [[nil, 5, nil], [nil, 9, nil]]
    assert Resolution.fill([], [], 2) == [[], []]
  end

  test "break_gaps puts a nil between samples too far apart" do
    assert Resolution.break_gaps([{0, 1}, {60, 2}, {400, 3}], 150) ==
             {[0, 60, 230, 400], [1, 2, nil, 3]}
  end

  property "after break_gaps, consecutive non-nil points are never more than the gap apart" do
    check all(ts <- uniq_list_of(integer(0..10_000), max_length: 60)) do
      samples = ts |> Enum.sort() |> Enum.map(&{&1, 1})
      {t, v} = Resolution.break_gaps(samples, 150)

      assert Enum.count(v, &is_nil/1) + length(samples) == length(t)

      Enum.zip(t, v)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{a, va}, {b, vb}] ->
        assert b > a
        if va && vb, do: assert(b - a <= 150)
      end)
    end
  end
end
