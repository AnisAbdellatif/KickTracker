defmodule KickTracker.BulkTest do
  @moduledoc "Bulk mode writes what live collection would have, consistently."

  # Not async: writes hypertables (see StatsTest).
  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Bulk, Metrics}

  @from ~U[2026-03-02 00:00:00Z]
  @to ~U[2026-03-05 00:00:00Z]

  setup do
    scenario =
      Sim.Scenario.new(
        seed: 3,
        channels: [
          [
            slug: "dailystreamer",
            peak_viewers: 300,
            schedule: %{days: [1, 2, 3, 4, 5, 6, 7], start_hour: 20, duration_min: 120}
          ],
          [slug: "neverstreamer", schedule: :never]
        ]
      )

    totals = Bulk.run(scenario, @from, @to)
    %{scenario: scenario, totals: totals}
  end

  test "streams, samples, changes, facts and chat for the live channel; followers for both",
       %{totals: totals} do
    assert totals.streams == 3
    streams = rows("streams", ["started_at"])
    assert length(streams) == 3
    assert Enum.all?(streams, &(&1.end_source == "event"))

    # About a sample a minute for two hours.
    assert totals.samples in (3 * 118)..(3 * 120)
    assert length(rows("viewer_samples", ["observed_at"])) == totals.samples

    # Every stream starts with its values, and its category changes have old values.
    changes = rows("stream_changes", ["occurred_at", "field"])
    assert Enum.count(changes, &is_nil(&1.old_value)) == 3 * 4
    assert rows("follows", ["message_id"]) != []
    assert Enum.sum_by(rows("chat_minutes", ["minute"]), & &1.messages) == totals.messages

    [c1, c2] = rows("channels", ["id"])
    followers = rows("follower_samples", ["observed_at"])
    assert Enum.any?(followers, &(&1.channel_id == c1.id))
    # The offline channel: one reading a day.
    assert Enum.count(followers, &(&1.channel_id == c2.id)) == 3
  end

  test "the rollups agree with the raw data" do
    [s | _] = rows("streams", ["started_at"])
    [stats] = rows("stream_stats", ["stream_id"]) |> Enum.filter(&(&1.stream_id == s.id))

    samples =
      rows("viewer_samples", ["observed_at"])
      |> Enum.filter(&(&1.stream_id == s.id))
      |> Enum.map(&{&1.observed_at, &1.viewers})

    assert_in_delta stats.hours_watched, Metrics.hours_watched(s.started_at, samples), 1.0e-6
    assert stats.airtime_s == 7200
    assert is_integer(stats.follower_gain)

    hourly = rows("hourly_stats", ["hour"])
    total = rows("stream_stats", ["stream_id"]) |> Enum.sum_by(& &1.hours_watched)
    assert_in_delta Enum.sum_by(hourly, &(&1.hours_watched || 0)), total, 1.0e-6
  end

  test "running it again changes nothing", %{scenario: scenario} do
    counts = fn ->
      for t <-
            ~w(streams viewer_samples follows support_events chat_minutes chat_stream_users follower_samples),
          do: length(rows(t, ["1"]))
    end

    before = counts.()
    Bulk.run(scenario, @from, @to)
    assert counts.() == before
  end
end
