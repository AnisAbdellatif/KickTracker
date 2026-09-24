defmodule KickTrackerWeb.PeriodTest do
  use ExUnit.Case, async: true

  alias KickTrackerWeb.Period

  @now ~U[2026-09-24 12:00:00Z]

  test "presets end now; unknown input falls back to the default" do
    p = Period.parse(%{"period" => "7d"}, now: @now)
    assert p.to == @now and DateTime.diff(p.to, p.from) == 7 * 86_400 and p.key == "7d"

    assert Period.parse(%{"period" => "bogus"}, now: @now).key == "30d"
    assert Period.parse(%{}, now: @now, default: "90d").key == "90d"
  end

  test "all starts at `since`" do
    since = ~U[2026-01-01 00:00:00Z]

    assert %{from: ^since, key: "all"} =
             Period.parse(%{"period" => "all"}, now: @now, since: since)
  end

  test "a custom range from unix seconds or ISO 8601, reproducible from its params" do
    p = Period.parse(%{"from" => "1790000000", "to" => "2026-09-24T00:00:00Z"}, now: @now)
    assert p.key == "custom"
    assert Period.parse(Period.to_params(p), now: @now) == p

    # Backwards or absurd ranges are ignored.
    assert Period.parse(%{"from" => "1790000000", "to" => "1780000000"}, now: @now).key == "30d"
  end

  test "a preset ends at the next whole minute, so requests within a minute share one period" do
    # Before, `to` was now to the second: every request a new cache key.
    a = Period.parse(%{"period" => "24h"}, now: ~U[2026-09-24 12:00:00.400000Z])
    b = Period.parse(%{"period" => "24h"}, now: ~U[2026-09-24 12:00:59Z])
    assert a == b
    assert a.to == ~U[2026-09-24 12:01:00Z]
    assert DateTime.diff(a.to, a.from) == 86_400
    # Still reaching past now: the latest reading is inside [from, to).
    assert DateTime.compare(a.to, ~U[2026-09-24 12:00:59Z]) == :gt

    all = Period.parse(%{"period" => "all"}, now: ~U[2026-09-24 12:00:10Z], since: @now)
    assert all.to == ~U[2026-09-24 12:01:00Z]
  end

  test "a custom range is at most 20 years long" do
    to = 1_790_000_000
    ok = Period.parse(%{"from" => to - Period.max_span_s(), "to" => to}, now: @now)
    assert ok.key == "custom"
    too_long = Period.parse(%{"from" => to - Period.max_span_s() - 1, "to" => to}, now: @now)
    assert too_long.key == "30d"
  end

  test "the previous period has the same length and ends where this one starts" do
    p = Period.parse(%{"period" => "7d"}, now: @now)
    prev = Period.previous(p)
    assert prev.to == p.from and DateTime.diff(prev.to, prev.from) == 7 * 86_400
  end
end
