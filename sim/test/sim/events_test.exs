defmodule Sim.EventsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sim.Events
  alias Sim.Scenario.Channel

  @channel Channel.new(slug: "somestreamer", peak_viewers: 500)

  defp over(minutes, viewers \\ 500, channel \\ @channel) do
    for m <- 0..(minutes - 1), event <- Events.for_minute(channel, viewers, m), do: event
  end

  defp kinds(events), do: events |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

  test "a stream's worth of events is a believable mix" do
    # A 3h stream with a few thousand viewers: hundreds of follows, tens of
    # subs, a handful of gift bursts, the rest rarer still.
    counts = kinds(over(180, 3_000))

    assert counts[:follow] in 200..800
    assert Map.get(counts, :sub, 0) in 1..60
    assert Map.get(counts, :resub, 0) in 1..80
    assert Map.get(counts, :gift, 0) <= 8
    assert Map.get(counts, :kicks, 0) in 1..80
    assert Map.get(counts, :ban, 0) <= 10
    assert counts[:follow] > Map.get(counts, :sub, 0)
  end

  test "every event type Kick documents is produced" do
    counts = kinds(over(3_000, 5_000))

    assert Map.keys(counts) |> Enum.sort() == [
             :ban,
             :follow,
             :gift,
             :kicks,
             :redemption,
             :resub,
             :sub
           ]
  end

  test "most gift bursts are small, a few are big" do
    sizes =
      for m <- 0..40_000,
          {:gift, _gifter, giftees} <- Events.for_minute(@channel, 5_000, m),
          do: length(giftees)

    assert sizes != []
    assert Enum.min(sizes) <= 5
    assert Enum.max(sizes) > 20
    assert Enum.count(sizes, &(&1 <= 5)) > Enum.count(sizes, &(&1 > 20))
  end

  test "the same minute always produces the same events" do
    assert Events.for_minute(@channel, 500, 42) == Events.for_minute(@channel, 500, 42)
    refute Events.for_minute(@channel, 500, 42) == Events.for_minute(@channel, 500, 43)
  end

  test "different channels produce different events from the same minute" do
    other = Channel.new(slug: "otherstreamer", peak_viewers: 500)
    refute Events.for_minute(@channel, 500, 10) == Events.for_minute(other, 500, 10)
  end

  test "a bigger audience produces more of everything" do
    small = length(over(240, 50))
    big = length(over(240, 20_000))

    assert big > small * 10
  end

  test "rare events land on some minutes and not others, rather than never" do
    subs = over(2_000) |> Enum.filter(&(elem(&1, 0) == :sub))

    minutes_with_subs =
      for m <- 0..1_999,
          Enum.any?(Events.for_minute(@channel, 500, m), &(elem(&1, 0) == :sub)),
          do: m

    assert subs != []
    assert length(minutes_with_subs) < 2_000
  end

  test "an empty channel produces nothing" do
    assert Events.for_minute(@channel, 0, 5) == []
  end

  test "gift bursts have giftees, sometimes an anonymous gifter" do
    gifts =
      for m <- 0..20_000,
          {:gift, gifter, giftees} <- Events.for_minute(@channel, 5_000, m),
          do: {gifter, giftees}

    assert gifts != []

    assert Enum.all?(gifts, fn {_gifter, giftees} ->
             giftees != [] and giftees == Enum.uniq(giftees)
           end)

    assert Enum.any?(gifts, fn {gifter, _} -> is_nil(gifter) end)
    assert Enum.any?(gifts, fn {gifter, _} -> is_integer(gifter) end)
  end

  test "resubs report a believable number of months" do
    resubs =
      for m <- 0..5_000,
          {:resub, _id, months} <- Events.for_minute(@channel, 2_000, m),
          do: months

    assert resubs != []
    assert Enum.all?(resubs, &(&1 in 2..31))
  end

  test "the people involved come from the channel's own audience" do
    pool = Sim.Curve.pool_size(@channel)

    people =
      for event <- over(500), id = person(event), is_integer(id), do: id

    assert people != []
    assert Enum.all?(people, &(&1 > @channel.user_id and &1 <= @channel.user_id + pool))
  end

  defp person({:follow, id}), do: id
  defp person({:sub, id, _}), do: id
  defp person({:resub, id, _}), do: id
  defp person({:gift, gifter, _}), do: gifter
  defp person({:kicks, id, _}), do: id
  defp person({:ban, _moderator, id, _}), do: id
  defp person({:redemption, id, _}), do: id

  property "events are well formed for any audience size and minute" do
    check all(viewers <- integer(0..100_000), minute <- integer(0..10_000)) do
      for event <- Events.for_minute(@channel, viewers, minute) do
        case event do
          {:follow, id} ->
            assert is_integer(id)

          {:sub, id, months} ->
            assert is_integer(id) and months >= 1

          {:resub, id, months} ->
            assert is_integer(id) and months >= 2

          {:gift, gifter, giftees} ->
            assert (is_nil(gifter) or is_integer(gifter)) and giftees != []

          {:kicks, id, amount} ->
            assert is_integer(id) and amount > 0

          {:ban, moderator, id, permanent?} ->
            assert is_integer(moderator) and is_integer(id) and is_boolean(permanent?)

          {:redemption, id, reward} ->
            assert is_integer(id) and is_map_key(reward, "title")
        end
      end
    end
  end
end
