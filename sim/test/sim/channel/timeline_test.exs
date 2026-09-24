defmodule Sim.Channel.TimelineTest do
  use ExUnit.Case, async: true

  alias Sim.Channel.Timeline
  alias Sim.Scenario.Channel
  alias Sim.{Schedule, StreamState}

  # Monday 20:00 to 23:00.
  @channel Channel.new(
             slug: "somestreamer",
             peak_viewers: 500,
             schedule: %{days: [1], start_hour: 20, duration_min: 180}
           )

  @before ~U[2026-01-05 19:59:30Z]
  @start ~U[2026-01-05 20:00:05Z]
  @after_end ~U[2026-01-05 23:00:05Z]

  defp names(emissions), do: Enum.map(emissions, &elem(&1, 0))

  defp body(emissions, event) do
    Enum.find_value(emissions, fn {name, body} -> if name == event, do: body end)
  end

  test "starting a channel announces nothing, even mid-stream" do
    state = Timeline.start(@channel, ~U[2026-01-05 21:00:00Z])
    assert {[], ^state} = Timeline.advance(@channel, state, ~U[2026-01-05 21:00:00Z])
  end

  test "going live sends status then metadata, in that order" do
    state = Timeline.start(@channel, @before)
    {emissions, state} = Timeline.advance(@channel, state, @start)

    assert names(emissions) == ["livestream.status.updated", "livestream.metadata.updated"]

    status = body(emissions, "livestream.status.updated")
    assert status["is_live"] == true
    assert status["ended_at"] == nil
    assert status["started_at"] == "2026-01-05T20:00:00Z"

    assert state.window.started_at == ~U[2026-01-05 20:00:00Z]
  end

  test "ending sends one status carrying when the stream really ended" do
    state = Timeline.start(@channel, ~U[2026-01-05 22:59:30Z])
    {emissions, state} = Timeline.advance(@channel, state, @after_end)

    assert names(emissions) == ["livestream.status.updated"]

    status = body(emissions, "livestream.status.updated")
    assert status["is_live"] == false
    assert status["started_at"] == "2026-01-05T20:00:00Z"
    # The window's end, not the moment we noticed five seconds later.
    assert status["ended_at"] == "2026-01-05T23:00:00Z"
    assert state.window == nil
  end

  test "a title or category change mid-stream sends metadata once" do
    [_first, second | _] = StreamState.segments(@channel, Schedule.stream_at(@channel, @start))

    just_before = DateTime.add(second.from, -1, :second)
    state = Timeline.start(@channel, just_before)

    {emissions, state} = Timeline.advance(@channel, state, second.from)
    assert "livestream.metadata.updated" in names(emissions)

    metadata = body(emissions, "livestream.metadata.updated")
    assert metadata["metadata"]["category"] == metadata["metadata"]["Category"]

    # The same segment again says nothing new about metadata.
    {again, _state} = Timeline.advance(@channel, state, DateTime.add(second.from, 30, :second))
    refute "livestream.metadata.updated" in names(again)
  end

  test "minutes that pass bring their own events, each minute only once" do
    state = Timeline.start(@channel, ~U[2026-01-05 20:00:00Z])

    {first, state} = Timeline.advance(@channel, state, ~U[2026-01-05 20:10:00Z])
    {repeat, state} = Timeline.advance(@channel, state, ~U[2026-01-05 20:10:30Z])
    {more, _state} = Timeline.advance(@channel, state, ~U[2026-01-05 20:20:00Z])

    assert "channel.followed" in names(first)
    assert repeat == []
    assert "channel.followed" in names(more)
  end

  test "a whole stream produces every event type a tracker must handle" do
    # Just past the three-hour stream, so the end is included.
    {events, _state} =
      Enum.reduce(0..185, {[], Timeline.start(@channel, @before)}, fn minute, {acc, state} ->
        at = DateTime.add(@before, minute * 60, :second)
        {emissions, state} = Timeline.advance(@channel, state, at)
        {acc ++ emissions, state}
      end)

    kinds = events |> names() |> Enum.frequencies()

    assert kinds["livestream.status.updated"] == 2
    assert kinds["livestream.metadata.updated"] >= 1
    assert kinds["channel.followed"] > 0
    assert Map.has_key?(kinds, "channel.subscription.new")
    assert Enum.all?(events, fn {_name, body} -> is_map(body["broadcaster"]) end)
  end

  test "a long gap doesn't replay everything that was missed" do
    state = Timeline.start(@channel, ~U[2026-01-05 20:00:00Z])
    {emissions, _state} = Timeline.advance(@channel, state, ~U[2026-01-05 22:30:00Z])

    # Two and a half hours passed; only the last hour of minutes is announced.
    follows = Enum.count(names(emissions), &(&1 == "channel.followed"))
    assert follows > 0
    assert follows < 150
  end

  test "an offline channel owes nothing at all" do
    channel = Channel.new(slug: "quiet", schedule: :never)
    state = Timeline.start(channel, @before)

    assert {[], _} = Timeline.advance(channel, state, @after_end)
  end
end
