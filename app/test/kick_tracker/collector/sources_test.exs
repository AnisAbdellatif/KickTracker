defmodule KickTracker.Collector.SourcesTest do
  @moduledoc "What each source makes of Kick's answers (the pure part; the sim tests cover the rest)."

  use ExUnit.Case, async: true

  alias KickTracker.Channels.Channel
  alias KickTracker.Collector.Sources.{Followers, Subscribers, Viewers}

  @at ~U[2026-09-01 12:00:00Z]
  defp channel(id, attrs \\ []),
    do: struct(%Channel{id: id, kick_user_id: 1000 + id, slug: "somestreamer#{id}"}, attrs)

  test "viewers: live, offline, and unknown are three different things" do
    [a, b] = [channel(1), channel(2)]
    state = Viewers.init([])
    {[unit], state} = Viewers.units([a, b], state, @at)

    live = [%{"broadcaster_user_id" => a.kick_user_id, "viewer_count" => 40}]
    {[], effects, state} = Viewers.record(unit, {:ok, live}, @at, state)

    assert {:send, a.kick_user_id, {:reading, hd(live), @at}} in effects
    assert {:send, b.kick_user_id, {:reading, :offline, @at}} in effects
    assert state.viewers == %{1 => 40}

    # A failed request says nothing about anyone.
    assert {[], [], ^state} = Viewers.record(unit, {:error, :timeout}, @at, state)
    assert Viewers.units(Enum.map(1..120, &channel/1), state, @at) |> elem(0) |> length() == 3
  end

  test "subscribers: totals, a rename, and no zero for a missing field" do
    [a, b] = [channel(1), channel(2)]

    found = [
      %{
        "broadcaster_user_id" => a.kick_user_id,
        "slug" => "renamed",
        "active_subscribers_count" => 5,
        "active_gifted_subscribers_count" => 1,
        "canceled_subscribers_count" => 0
      },
      %{"broadcaster_user_id" => b.kick_user_id, "slug" => b.slug}
    ]

    {ops, effects, _} = Subscribers.record(%{channels: [a, b]}, {:ok, found}, @at, %{})

    assert [{:subscriber_samples, [%{channel_id: 1, active: 5}]}, {:slug, 1, "renamed", @at}] =
             ops

    assert effects == [{:channel, %{a | slug: "renamed"}}]
  end

  test "followers: requests first, then who is due, a few at a time; failures wait" do
    live = channel(1)
    fresh = channel(2)
    stale = channel(3)
    never = channel(4)

    state = %{
      Followers.init(per_cycle: 2)
      | last: %{
          1 => DateTime.add(@at, -20 * 60),
          2 => DateTime.add(@at, -60),
          3 => DateTime.add(@at, -2 * 86_400)
        },
        requests: [2]
    }

    {units, state} = Followers.units([live, fresh, stale, never], state, @at)
    # The request, then the one never read (the oldest); `live` counts as
    # offline here (no live list), so it isn't due yet.
    assert Enum.map(units, &hd(&1.channels).id) == [2, 4]
    assert state.requests == []

    {ops, effects, state} =
      Followers.record(%{channels: [never]}, {:ok, %{followers: 9, chatroom_id: 77}}, @at, state)

    assert ops == [{:follower_sample, 4, @at, 9}, {:channel_ids, 4, nil, 77}]
    assert effects == [{:channel, %{never | chatroom_id: 77}}]

    {[], [], state} = Followers.record(%{channels: [stale]}, {:error, :timeout}, @at, state)
    {units, _} = Followers.units([stale], state, DateTime.add(@at, 60))
    assert units == []
  end
end
