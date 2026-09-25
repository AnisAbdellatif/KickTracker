defmodule KickTracker.ReportsTest do
  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Reports, Rollups}

  doctest Reports, only: [slugify: 1]

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

  test "weekdays are the channel's, and airtime is split at its midnight", %{c: c} do
    Repo.query!("UPDATE channels SET timezone = 'Africa/Tunis' WHERE id = $1", [c.id])
    c = KickTracker.Channels.get!(c.id)
    # 23:30 to 00:30 in Tunis, from Monday into Tuesday.
    stream!(c, at(150), at(210))
    days = Reports.weekdays(c, at(-60), at(1560))

    assert Enum.map(days, & &1.weekday) == Enum.to_list(1..7)
    [mon, tue, wed | _] = days
    assert mon.avg_viewers == 100.0 and tue.avg_viewers == 300.0
    assert_in_delta mon.hours_watched, 59 * 100 / 60, 0.01
    assert mon.airtime_s == 3600 + 1800 and tue.airtime_s == 3600 + 1800
    # No readings: unknown, not 0; no stream: no airtime.
    assert wed.hours_watched == nil and wed.avg_viewers == nil and wed.airtime_s == 0
  end

  test "slugs and search" do
    assert Reports.slugify("EA Sports FC 27") == "ea-sports-fc-27"
    assert Reports.slugify("Just Chatting") == "just-chatting"
    assert [%{slug: "somestreamer"}] = Reports.search("stream")
    assert Reports.search("100%") == []
  end

  defp category!(id, name) do
    Repo.query!(
      "INSERT INTO categories (id, name, first_seen_at, updated_at) VALUES ($1, $2, now(), now())",
      [id, name]
    )
  end

  test "category slugs work in any script, never empty, and tell equal slugs apart" do
    # Before: "", "" and a slug only the first "Just Chatting" answered to.
    assert Reports.slugify("Pokémon Go") == "pokemon-go"
    assert Reports.slugify("Игры") == "игры"
    assert Reports.slugify("ゲーム") == "ゲーム"
    assert "c-" <> _ = Reports.slugify("🎮")

    category!(9001, "Just Chatting")
    category!(9002, "just-chatting")
    category!(9003, "Игры")

    assert %{id: 9001} = Reports.category_by_slug("just-chatting")
    assert %{id: 9002} = Reports.category_by_slug("just-chatting-9002")
    assert %{id: 9001} = Reports.category_by_slug("Just-Chatting")
    assert %{id: 9003} = Reports.category_by_slug("ИГРЫ")
    assert Reports.category_by_slug("nothing-here") == nil
  end

  test "follower gain for a period starting before the first reading, as \"all\" does", %{c: c} do
    Repo.insert_all("follower_samples", [
      %{channel_id: c.id, observed_at: at(5), followers: 1000},
      %{channel_id: c.id, observed_at: at(1450), followers: 1100}
    ])

    # Before: nil, for want of a reading at or just before the start.
    p = Reports.period(c, at(-600), at(1560))
    assert p.follower_gain == 100
    assert DateTime.compare(p.follower_gain_since, at(5)) == :eq

    # With a reading at the start, the gain is over the whole period.
    Repo.insert_all("follower_samples", [
      %{channel_id: c.id, observed_at: at(-700), followers: 900}
    ])

    p = Reports.period(c, at(-600), at(1560))
    assert p.follower_gain == 200 and p.follower_gain_since == nil
  end

  test "the follower gain leaderboard: one query for every channel, the same figures", %{c: c} do
    other = channel!(slug: "otherstreamer")
    third = channel!(slug: "thirdstreamer")

    Repo.insert_all("follower_samples", [
      %{channel_id: c.id, observed_at: at(-30), followers: 1000},
      %{channel_id: c.id, observed_at: at(1550), followers: 1250},
      %{channel_id: other.id, observed_at: at(-30), followers: 50},
      %{channel_id: other.id, observed_at: at(1550), followers: 60}
    ])

    board = Reports.leaderboard(at(-10), at(1560), "follower_gain")

    assert [{c.id, 250}, {other.id, 10}, {third.id, nil}] ==
             Enum.map(board, &{&1.channel_id, &1.follower_gain})

    for r <- board do
      assert r.follower_gain == Reports.period(ch(r.channel_id), at(-10), at(1560)).follower_gain
    end
  end

  defp ch(id), do: KickTracker.Channels.get!(id)

  test "notable moments: a stream beating the channel's earlier peaks is a record", %{
    c: c,
    s2: s2
  } do
    # A third, weaker stream: no record. An excluded stream's higher peak
    # before it doesn't count.
    s3 = stream!(c, at(3000), at(3060))
    samples!(c, s3, for(m <- 3000..3059, do: {at(m), 200}))
    s4 = stream!(c, at(4000), at(4060))
    samples!(c, s4, for(m <- 4000..4059, do: {at(m), 900}))
    s5 = stream!(c, at(5000), at(5060))
    samples!(c, s5, for(m <- 5000..5059, do: {at(m), 500}))
    Enum.each([s3, s4, s5], &Rollups.stream_stats/1)

    Repo.query!(
      "INSERT INTO stream_overrides (kind, stream_id, inserted_at) VALUES ('exclude', $1, now())",
      [s4]
    )

    # A channel's first stream is never a record.
    other = channel!(slug: "otherstreamer")
    o1 = stream!(other, at(10), at(70))
    samples!(other, o1, for(m <- 10..69, do: {at(m), 10_000}))
    Rollups.stream_stats(o1)

    records =
      Reports.notable(at(-60), at(6000), 20) |> Enum.filter(&(&1.kind == "record"))

    assert [{s5, 500}, {s2, 300}] ==
             Enum.map(Enum.sort_by(records, &(-&1.value)), &{&1.stream_id, &1.value})
  end

  test "category figures weigh the first sample in range from its real previous one" do
    c = channel!()
    category!(77, "Somecategory")
    s = stream!(c, at(0), at(120))
    samples!(c, s, for(m <- 1..119, do: {at(m), 1000}), 77)
    Rollups.hourly(at(0), at(120))

    from = DateTime.add(at(60), 30)
    to = at(120)
    [cat] = Reports.categories(c, from, to)
    # 59 samples in range (minutes 61..119), each 60s after the previous.
    # Before, the first was weighted from the stream's start (75s).
    assert_in_delta cat.hours_watched, 59 * 1000 * 60 / 3600, 1.0e-6
    assert cat.airtime_s == 59 * 60

    [row] = Reports.category_channels(77, from, to)
    assert_in_delta row.hours_watched, 59 * 1000 * 60 / 3600, 1.0e-6

    # From the start of an hour, the categories agree with hourly_stats.
    [cat] = Reports.categories(c, at(60), at(120))

    %{rows: [[hourly]]} =
      Repo.query!("SELECT hours_watched FROM hourly_stats WHERE channel_id = $1 AND hour = $2", [
        c.id,
        at(60)
      ])

    assert_in_delta cat.hours_watched, hourly, 1.0e-6
  end

  test "a flagged reading is never a category's peak" do
    c = channel!()
    category!(78, "Othercategory")
    s = stream!(c, at(0), at(10))

    samples!(
      c,
      s,
      for({v, i} <- Enum.with_index([500, 510, 9000, 505, 498]), do: {at(1 + i), v}),
      78
    )

    Rollups.hourly(at(0), at(10))

    # Before: 9000.
    assert [%{peak_viewers: 510}] = Reports.category_channels(78, at(0), at(10))
  end

  test "an excluded stream is in no chatter figure", %{c: c, s1: s1, s2: s2} do
    other = channel!(slug: "otherstreamer")
    o1 = stream!(other, at(10), at(70))

    Repo.insert_all(
      "chat_stream_users",
      for(
        {sid, u} <- [{s1, 1}, {s2, 2}, {o1, 1}],
        do: %{stream_id: sid, user_id: u, messages: 1, first_at: at(0), last_at: at(0)}
      )
    )

    Repo.query!(
      "INSERT INTO stream_overrides (kind, stream_id, inserted_at) VALUES ('exclude', $1, now())",
      [s1]
    )

    Enum.each([s1, s2], &Rollups.stream_stats/1)

    # Before, the excluded stream was listed too.
    assert [%{stream_id: ^s2, new: 1}] = Reports.chatter_retention(c, at(-60), at(1560))
    # User 1 chatted in both channels, but here only in the excluded
    # stream: before, counted as shared.
    assert %{counts: counts, pairs: pairs} =
             Reports.overlap([c.id, other.id], at(-60), at(1560))

    assert pairs == %{} and counts[c.id] == 1

    Repo.query!("UPDATE stream_overrides SET revoked_at = now() WHERE stream_id = $1", [s1])
    assert %{counts: counts, pairs: pairs} = Reports.overlap([c.id, other.id], at(-60), at(1560))
    assert counts[c.id] == 2 and Map.values(pairs) == [1]
  end

  test "webhook sums are unknown with no ingress coverage, and say how covered they are", %{
    c: c
  } do
    Repo.insert_all("follows", [
      %{message_id: "f", channel_id: c.id, occurred_at: at(10), user_id: 1}
    ])

    # Tracked since before the period: time before tracking isn't a gap.
    Repo.query!("UPDATE channels SET tracked_since = $2 WHERE id = $1", [c.id, at(-600)])
    c = KickTracker.Channels.get!(c.id)
    Rollups.hourly(at(0), at(60))
    p = Reports.period(c, at(0), at(60))
    assert p.follows == nil and p.kicks == nil and p.ingress_coverage == 0.0

    covered!(c, "ingress", at(0), at(30))
    p = Reports.period(c, at(0), at(60))
    assert p.follows == 1 and p.kicks == 0
    assert p.ingress_coverage > 0.5 and p.ingress_coverage < 1.0
  end
end
