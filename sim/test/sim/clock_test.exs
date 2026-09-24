defmodule Sim.ClockTest do
  use ExUnit.Case, async: true
  doctest Sim.Clock

  alias Sim.Clock

  test "at real speed simulated time tracks real time" do
    clock = Clock.new(sim_start: ~U[2026-01-01 00:00:00Z], real_now_ms: 5_000)

    assert Clock.now(clock, 5_000) == ~U[2026-01-01 00:00:00.000Z]
    assert Clock.now(clock, 5_000 + 90_000) == ~U[2026-01-01 00:01:30.000Z]
  end

  test "speed makes the simulation run faster, and says how long a span really takes" do
    clock = Clock.new(sim_start: ~U[2026-01-01 00:00:00Z], speed: 120, real_now_ms: 0)

    # Two real minutes are four simulated hours.
    assert Clock.now(clock, 120_000) == ~U[2026-01-01 04:00:00.000Z]
    # A simulated day passes in twelve real minutes.
    assert Clock.real_ms_for(clock, 24 * 3_600_000) == 720_000
  end

  test "the simulated start can be in the past, for generating history" do
    clock = Clock.new(sim_start: ~U[2025-06-01 12:00:00Z], real_now_ms: 1_000)
    assert Clock.now(clock, 1_000) == ~U[2025-06-01 12:00:00.000Z]
  end

  test "a speed that isn't a positive number is refused" do
    assert_raise ArgumentError, ~r/positive number/, fn -> Clock.new(speed: 0) end
    assert_raise ArgumentError, ~r/positive number/, fn -> Clock.new(speed: "fast") end
  end
end
