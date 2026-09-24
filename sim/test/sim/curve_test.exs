defmodule Sim.CurveTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sim.Curve
  alias Sim.Scenario.Channel

  @duration 4 * 3600
  @channel Channel.new(slug: "somestreamer", peak_viewers: 500)

  defp viewers(elapsed_s, channel \\ @channel), do: Curve.viewers(channel, elapsed_s, @duration)

  test "viewers hold still within a minute and move between minutes, like Kick's own count" do
    within = Enum.map([0, 15, 30, 59], &viewers(3600 + &1))
    assert length(Enum.uniq(within)) == 1
    assert viewers(3660) != viewers(3600)
  end

  test "the same stream always looks the same, and different channels differ" do
    other = Channel.new(slug: "otherstreamer", peak_viewers: 500)

    assert viewers(1800) == viewers(1800)
    assert viewers(1800, other) != viewers(1800)
  end

  test "the audience arrives, sits, and drifts away" do
    start = viewers(0)
    ramped = viewers(20 * 60)
    middle = viewers(@duration |> div(2))
    ending = viewers(@duration - 60)

    assert start < ramped
    assert ending < middle
    assert ending < ramped
  end

  test "viewers stay near the channel's size, and a bigger channel is bigger" do
    counts = for m <- 0..(div(@duration, 60) - 1), do: viewers(m * 60)

    assert Enum.max(counts) <= @channel.peak_viewers * 1.1
    # The quietest minute is the first: the ramp starts at a quarter of peak.
    assert Enum.min(counts) >= @channel.peak_viewers * 0.2
    assert Enum.min(counts) == hd(counts)

    big = Channel.new(slug: "bigstreamer", peak_viewers: 20_000)
    assert Curve.viewers(big, 1800, @duration) > 10 * viewers(1800)
  end

  test "chat scales with the audience and repeats the same people" do
    messages = Curve.messages_per_minute(@channel, 500, 1800)
    quiet = Curve.messages_per_minute(@channel, 20, 1800)

    assert messages > quiet
    assert messages in 10..50

    chatters = Curve.chatters(@channel, messages, 1800)
    assert length(chatters) > 0
    assert length(chatters) <= messages
    assert chatters == Enum.uniq(chatters)

    # Over a stream, the same people come back rather than each minute being
    # a brand new crowd.
    per_minute = for m <- 0..59, do: MapSet.new(Curve.chatters(@channel, messages, m * 60))
    everyone = Enum.reduce(per_minute, MapSet.new(), &MapSet.union/2)
    total = Enum.sum(Enum.map(per_minute, &MapSet.size/1))

    assert MapSet.size(everyone) < total
    assert MapSet.size(everyone) <= Curve.pool_size(@channel)
  end

  test "a silent minute produces no chatters" do
    assert Curve.chatters(@channel, 0, 60) == []
  end

  test "followers stay in proportion to the channel and climb slowly" do
    small = Channel.new(slug: "smallstreamer", peak_viewers: 50)
    big = Channel.new(slug: "bigstreamer", peak_viewers: 20_000)
    at = ~U[2026-06-01 00:00:00Z]

    # Roughly 40 followers per peak viewer, as the recordings showed, and a
    # few months of growth on top rather than decades of it.
    assert Curve.followers(small, at) in 2_000..20_000
    assert Curve.followers(big, at) in 800_000..2_000_000
    assert Curve.followers_per_day(big) > Curve.followers_per_day(small)
  end

  test "followers only ever climb" do
    days =
      for d <- 0..30,
          do: Curve.followers(@channel, DateTime.add(~U[2026-01-01 00:00:00Z], d, :day))

    assert days == Enum.sort(days)
    assert List.last(days) > hd(days)
  end

  property "viewers are always a sensible count, whenever you ask" do
    check all(elapsed <- integer(-100..(@duration + 100))) do
      viewers = viewers(elapsed)
      assert viewers >= 1
      assert viewers <= @channel.peak_viewers * 1.2
    end
  end

  property "chat is never negative and never more chatters than messages" do
    check all(viewers <- integer(0..50_000), elapsed <- integer(0..@duration)) do
      messages = Curve.messages_per_minute(@channel, viewers, elapsed)
      assert messages >= 0
      assert length(Curve.chatters(@channel, messages, elapsed)) <= messages
    end
  end
end
