defmodule KickTracker.Stats.CoverageTest do
  use KickTracker.DataCase, async: true

  import KickTracker.Fixtures
  alias KickTracker.Stats.Coverage

  @t ~U[2026-01-05 20:00:00.000000Z]
  defp at(s), do: DateTime.add(@t, s)

  defp periods(c) do
    for r <- rows("coverage", ["from_at", "id"]),
        r.channel_id == c.id,
        do: {DateTime.diff(r.from_at, @t), DateTime.diff(r.to_at, @t), r.ok}
  end

  test "consecutive outcomes extend a period; a failure, or silence, starts a new one" do
    c = channel!()

    for s <- [0, 60, 120], do: Coverage.mark([c.id], "api", true, at(s), 150)
    Coverage.mark([c.id], "api", false, at(180), 150)
    Coverage.mark([c.id], "api", true, at(240), 150)
    # Nothing for ten minutes (the collector was down): a gap, then a new period.
    Coverage.mark([c.id], "api", true, at(840), 150)

    assert periods(c) == [{0, 120, true}, {180, 180, false}, {240, 240, true}, {840, 840, true}]
  end

  test "sources are kept apart" do
    c = channel!()
    Coverage.mark([c.id], "api", true, at(0), 150)
    Coverage.mark([c.id], "subscribers", true, at(60), 660)
    Coverage.mark([c.id], "api", true, at(60), 150)
    assert periods(c) == [{0, 60, true}, {60, 60, true}]
  end
end
