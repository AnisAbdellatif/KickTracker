defmodule Sim.ScheduleTest do
  use ExUnit.Case, async: true

  alias Sim.Scenario.Channel
  alias Sim.Schedule

  # 2026-01-05 is a Monday.
  defp evenings(opts \\ []) do
    Channel.new(
      slug: "somestreamer",
      schedule: Map.new([{:days, [1, 3]}, {:start_hour, 20}, {:duration_min, 180}] ++ opts)
    )
  end

  test "a daily schedule is live only inside its window" do
    channel = evenings()

    refute Schedule.live?(channel, ~U[2026-01-05 19:59:59Z])
    assert Schedule.live?(channel, ~U[2026-01-05 20:00:00Z])
    assert Schedule.live?(channel, ~U[2026-01-05 22:59:59Z])
    refute Schedule.live?(channel, ~U[2026-01-05 23:00:00Z])
    # Tuesday isn't a streaming day.
    refute Schedule.live?(channel, ~U[2026-01-06 21:00:00Z])
    assert Schedule.live?(channel, ~U[2026-01-07 21:00:00Z])
  end

  test "the window reports Kick's own start and end" do
    assert %{
             started_at: ~U[2026-01-05 20:00:00Z],
             ends_at: ~U[2026-01-05 23:00:00Z],
             duration_s: 10_800
           } =
             Schedule.stream_at(evenings(), ~U[2026-01-05 21:30:00Z])
  end

  test "a stream that crosses midnight is still one stream, with yesterday's start" do
    channel = evenings(start_hour: 23, duration_min: 240)

    assert %{started_at: ~U[2026-01-05 23:00:00Z]} =
             Schedule.stream_at(channel, ~U[2026-01-06 02:59:00Z])

    refute Schedule.live?(channel, ~U[2026-01-06 03:00:00Z])
  end

  test "a stream longer than a day is found from several days back" do
    channel = evenings(days: [1], start_hour: 10, duration_min: 3 * 1440)

    assert %{started_at: ~U[2026-01-05 10:00:00Z]} =
             Schedule.stream_at(channel, ~U[2026-01-07 09:00:00Z])

    refute Schedule.live?(channel, ~U[2026-01-08 11:00:00Z])
  end

  test ":always is one stream a day, starting at midnight" do
    channel = Channel.new(slug: "somestreamer", schedule: :always)

    assert Schedule.live?(channel, ~U[2026-01-05 00:00:00Z])
    assert Schedule.live?(channel, ~U[2026-01-05 23:59:59Z])

    assert %{started_at: ~U[2026-01-06 00:00:00Z]} =
             Schedule.stream_at(channel, ~U[2026-01-06 12:00:00Z])
  end

  test ":never is never live and has no next start" do
    channel = Channel.new(slug: "somestreamer", schedule: :never)

    refute Schedule.live?(channel, ~U[2026-01-05 20:00:00Z])
    assert Schedule.stream_at(channel, ~U[2026-01-05 20:00:00Z]) == nil
    assert Schedule.next_start(channel, ~U[2026-01-05 20:00:00Z]) == nil

    assert Schedule.windows_between(channel, ~U[2026-01-01 00:00:00Z], ~U[2026-02-01 00:00:00Z]) ==
             []
  end

  test "next_start finds the coming stream, including one already running today" do
    channel = evenings()

    assert Schedule.next_start(channel, ~U[2026-01-05 08:00:00Z]) == ~U[2026-01-05 20:00:00Z]
    # Monday's is over, so Wednesday is next.
    assert Schedule.next_start(channel, ~U[2026-01-05 23:30:00Z]) == ~U[2026-01-07 20:00:00Z]
  end

  test "windows_between gives the history of a month without simulating it" do
    windows =
      Schedule.windows_between(evenings(), ~U[2026-01-01 00:00:00Z], ~U[2026-02-01 00:00:00Z])

    # Two streams a week: 4 Mondays and 4 Wednesdays in January 2026.
    assert length(windows) == 8

    assert Enum.map(windows, & &1.started_at) ==
             Enum.sort(Enum.map(windows, & &1.started_at), DateTime)

    assert hd(windows).started_at == ~U[2026-01-05 20:00:00Z]
    assert Enum.all?(windows, &(Date.day_of_week(DateTime.to_date(&1.started_at)) in [1, 3]))
  end

  test "windows_between includes a stream that only overlaps the edges of the range" do
    channel = evenings()

    assert [%{started_at: ~U[2026-01-05 20:00:00Z]}] =
             Schedule.windows_between(channel, ~U[2026-01-05 22:00:00Z], ~U[2026-01-05 22:30:00Z])
  end
end
