defmodule Sim.ScenarioTest do
  use ExUnit.Case, async: true

  alias Sim.Scenario
  alias Sim.Scenario.Channel

  test "a channel needs only a slug; ids and seed come from it and are stable" do
    a = Channel.new(slug: "somestreamer")
    b = Channel.new(slug: "somestreamer")
    other = Channel.new(slug: "otherstreamer")

    assert a == b
    assert a.username == "somestreamer"
    assert a.user_id != a.channel_id and a.channel_id != a.chatroom_id
    assert a.user_id != other.user_id
    assert a.peak_viewers > 0
    assert a.schedule == :always
  end

  test "given values win over derived ones" do
    channel = Channel.new(slug: "somestreamer", user_id: 42, peak_viewers: 9, language: "ar")

    assert channel.user_id == 42
    assert channel.peak_viewers == 9
    assert channel.language == "ar"
  end

  test "a typo in a channel option fails loudly instead of being ignored" do
    assert_raise ArgumentError, ~r/unknown channel options/, fn ->
      Channel.new(slug: "somestreamer", peak_viewrs: 10)
    end

    assert_raise ArgumentError, ~r/needs a :slug/, fn -> Channel.new(peak_viewers: 10) end
  end

  test "schedules are validated" do
    assert Channel.new(slug: "a", schedule: %{days: [1, 3], start_hour: 21, duration_min: 90}).schedule ==
             %{days: [1, 3], start_hour: 21, start_minute: 0, duration_min: 90}

    for bad <- [%{days: []}, %{days: [0]}, %{days: [8]}, %{start_hour: 24}, %{duration_min: 0}] do
      assert_raise ArgumentError, fn -> Channel.new(Map.put(bad, :slug, "a")) end
    end
  end

  test "a scenario looks channels up by slug (any case) and by broadcaster id" do
    scenario = Scenario.new(channels: [[slug: "somestreamer"], [slug: "otherstreamer"]])

    assert %Channel{slug: "somestreamer"} = Scenario.channel(scenario, "SomeStreamer")
    assert Scenario.channel(scenario, "nobody") == nil

    channel = Scenario.channel(scenario, "otherstreamer")
    assert Scenario.channel_by_user_id(scenario, channel.user_id).slug == "otherstreamer"
    assert Scenario.channel_by_user_id(scenario, 1) == nil
  end

  test "two channels with the same slug are refused" do
    assert_raise ArgumentError, ~r/duplicate channel slug/, fn ->
      Scenario.new(channels: [[slug: "somestreamer"], [slug: "somestreamer"]])
    end
  end

  test "channels in one scenario get different seeds even with the same settings" do
    scenario = Scenario.new(channels: [[slug: "a"], [slug: "b"]])
    assert scenario.channels |> Enum.map(& &1.seed) |> Enum.uniq() |> length() == 2
  end

  test "faults are read with a default" do
    scenario = Scenario.new(faults: [drop_webhooks: 0.5])

    assert Scenario.fault(scenario, :drop_webhooks) == 0.5
    assert Scenario.fault(scenario, :never_set) == false
    assert Scenario.fault(scenario, :never_set, :fallback) == :fallback
  end
end
