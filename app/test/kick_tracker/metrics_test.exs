defmodule KickTracker.MetricsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Metrics

  @s ~U[2026-01-05 20:00:00.000000Z]
  defp at(s), do: DateTime.add(@s, s)

  describe "hours watched" do
    test "a sample every 60s counts 60s each, the first from the stream's start" do
      samples = for m <- 1..60, do: {at(m * 60), 100}
      assert_in_delta Metrics.hours_watched(@s, samples), 100.0, 1.0e-9
    end

    test "a late poll counts its real interval, up to 75s" do
      assert_in_delta Metrics.hours_watched(@s, [{at(60), 3600}, {at(130), 3600}]),
                      (60 + 70) / 1,
                      1.0e-9
    end

    test "a gap is never filled: a missed poll adds at most 15s, a long outage 75s" do
      # 60s, then a missed poll (120s), then a 10-minute outage.
      samples = [{at(60), 3600}, {at(180), 3600}, {at(780), 3600}]
      assert_in_delta Metrics.hours_watched(@s, samples), 60 + 75 + 75, 1.0e-9
    end

    test "no samples, no hours" do
      assert Metrics.hours_watched(@s, []) == 0.0
    end

    property "any order, the same total; never more than 75s per sample" do
      check all(
              gaps <- list_of(integer(1..600), max_length: 100),
              viewers <- list_of(integer(0..50_000), length: length(gaps))
            ) do
        times = Enum.scan(gaps, &(&1 + &2))
        samples = Enum.zip(Enum.map(times, &at/1), viewers)
        total = Metrics.hours_watched(@s, samples)

        assert_in_delta total, Metrics.hours_watched(@s, Enum.shuffle(samples)), 1.0e-6
        assert total <= Enum.sum(viewers) * 75 / 3600 + 1.0e-6
      end
    end
  end

  test "average and peak; no samples is unknown, not zero" do
    assert Metrics.viewers([{at(60), 10}, {at(120), 30}]) == %{samples: 2, avg: 20.0, peak: 30}
    assert Metrics.viewers([]) == %{samples: 0, avg: nil, peak: nil}
  end

  describe "follower gain" do
    test "from the readings closest to the start and end" do
      readings = [{at(-100), 1000}, {at(30), 1003}, {at(3600), 1050}, {at(7300), 1100}]
      assert Metrics.follower_gain(@s, at(7200), readings) == %{start: 1003, end: 1100, gain: 97}
    end

    test "no reading near the end: the gain is unknown, not zero" do
      assert Metrics.follower_gain(@s, at(7200), [{at(10), 5}]) == %{
               start: 5,
               end: nil,
               gain: nil
             }

      assert Metrics.follower_gain(@s, nil, [{at(10), 5}]) == %{start: 5, end: nil, gain: nil}
    end

    test "a short stream's one reading isn't both its start and its end" do
      assert Metrics.follower_gain(@s, at(300), [{at(100), 5}]) == %{
               start: 5,
               end: nil,
               gain: nil
             }
    end
  end
end
