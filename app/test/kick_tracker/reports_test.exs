defmodule KickTracker.ReportsTest do
  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Reports, Rollups}

  @t0 ~U[2026-03-02 20:00:00Z]
  defp at(min), do: DateTime.add(@t0, min * 60)

  setup do
    c = channel!(slug: "somestreamer")
    s1 = stream!(c, at(0), at(60))
    samples!(c, s1, for(m <- 0..59, do: {at(m), 100}))
    s2 = stream!(c, at(1440), at(1500))
    samples!(c, s2, for(m <- 1440..1499, do: {at(m), 300}))
    Rollups.hourly(at(0), at(1500))
    Enum.each([s1, s2], &Rollups.stream_stats/1)
    %{c: c, s1: s1, s2: s2}
  end

  test "period figures: hours watched, averages, airtime; unknown follower gain is nil", %{c: c} do
    p = Reports.period(c, at(-60), at(1560))
    # The first reading of each stream is at its start and weighs nothing.
    assert_in_delta p.hours_watched, (59 * 100 + 59 * 300) / 60, 0.01
    assert p.avg_viewers == 200.0 and p.peak_viewers == 300
    assert p.streams == 2 and p.airtime_s == 7200
    assert p.follower_gain == nil
  end

  test "follower gain comes from readings near both ends", %{c: c} do
    Repo.insert_all("follower_samples", [
      %{channel_id: c.id, observed_at: at(-30), followers: 1000},
      %{channel_id: c.id, observed_at: at(1550), followers: 1250}
    ])

    assert Reports.period(c, at(-10), at(1560)).follower_gain == 250
  end

  test "an excluded stream leaves the stream figures and records, and is marked", %{c: c, s2: s2} do
    Repo.query!(
      "INSERT INTO stream_overrides (kind, stream_id, inserted_at) VALUES ('exclude', $1, now())",
      [s2]
    )

    Rollups.hourly(at(0), at(1500))
    p = Reports.period(c, at(-60), at(1560))
    assert p.streams == 1 and p.airtime_s == 3600
    # Its viewers are gone from the channel's figures too.
    assert p.peak_viewers == 100 and p.avg_viewers == 100.0
    assert Reports.records(c).peak.peak_viewers == 100
    assert [%{id: ^s2, excluded?: true}, %{excluded?: false}] = Reports.streams(c)
  end

  test "leaderboards rank channels, unknown figures last", %{c: c} do
    other = channel!(slug: "otherstreamer")
    board = Reports.leaderboard(at(-60), at(1560), "avg_viewers")
    assert [%{channel_id: first}, %{channel_id: last}] = board
    assert first == c.id and last == other.id
  end

  test "the heatmap is 7 × 24 in the channel's timezone", %{c: c} do
    Repo.query!("UPDATE channels SET timezone = 'Africa/Tunis' WHERE id = $1", [c.id])
    c = KickTracker.Channels.get!(c.id)
    map = Reports.heatmap(c, at(-60), at(1560))
    assert length(map) == 7 and Enum.all?(map, &(length(&1) == 24))
    # 2026-03-02 is a Monday; 20:00 UTC is 21:00 in Tunis.
    assert Enum.at(Enum.at(map, 0), 21) == 100
    assert Enum.at(Enum.at(map, 0), 20) == nil
  end

  test "slugs and search" do
    assert Reports.slugify("EA Sports FC 27") == "ea-sports-fc-27"
    assert Reports.slugify("Just Chatting") == "just-chatting"
    assert [%{slug: "somestreamer"}] = Reports.search("stream")
    assert Reports.search("100%") == []
  end
end
