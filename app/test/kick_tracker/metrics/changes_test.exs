defmodule KickTracker.Metrics.ChangesTest do
  use ExUnit.Case, async: true

  alias KickTracker.Metrics.Changes

  @t ~U[2026-01-05 20:00:00Z]
  defp at(s), do: DateTime.add(@t, s)

  defp snap(title, category \\ "15"),
    do: %{"title" => title, "category" => category, "language" => "en", "mature" => "false"}

  defp fields(changes), do: Enum.map(changes, &{&1.field, &1.old_value, &1.new_value, &1.source})

  test "the first snapshot records what the stream started with" do
    {_, changes} = Changes.event(Changes.new(), snap("hello"), at(1))

    assert fields(changes) == [
             {"title", nil, "hello", :event},
             {"category", nil, "15", :event},
             {"language", nil, "en", :event},
             {"mature", nil, "false", :event}
           ]
  end

  test "a full snapshot yields only the fields that changed" do
    {state, _} = Changes.event(Changes.new(), snap("hello"), at(1))
    {_, changes} = Changes.event(state, snap("hello", "42"), at(600))
    assert [%{field: "category", old_value: "15", new_value: "42", occurred_at: t}] = changes
    assert t == at(600)
  end

  test "an older snapshot arriving late is ignored" do
    {state, _} = Changes.event(Changes.new(), snap("new"), at(600))
    assert {^state, []} = Changes.event(state, snap("old"), at(300))
  end

  test "the poll counts a difference seen twice in a row, dated at the first sighting" do
    {state, _} = Changes.poll(Changes.new(), snap("a"), at(0))
    {state, []} = Changes.poll(state, snap("b"), at(60))
    {state, changes} = Changes.poll(state, snap("b"), at(120))

    assert [%{field: "title", old_value: "a", new_value: "b", occurred_at: first, source: :poll}] =
             changes

    assert first == at(60)

    # A value seen once, then back to the known one, is nothing.
    {state, []} = Changes.poll(state, snap("c"), at(180))
    assert {_, []} = Changes.poll(state, snap("b"), at(240))
  end

  test "right after an event, the lagging poll can't undo it" do
    {state, _} = Changes.event(Changes.new(), snap("old"), at(0))
    {state, _} = Changes.event(state, snap("new"), at(600))

    {state, []} = Changes.poll(state, snap("old"), at(620))
    {state, []} = Changes.poll(state, snap("old"), at(680))
    assert {_, []} = Changes.poll(state, snap("new"), at(740))
  end

  test "a category going away is a change" do
    {state, _} = Changes.event(Changes.new(), snap("t"), at(0))

    assert {_, [%{field: "category", old_value: "15", new_value: nil}]} =
             Changes.event(state, snap("t", nil), at(60))
  end

  test "snapshots from Kick's shapes: the event reads the lowercase category" do
    body = %{
      "metadata" => %{
        "title" => "t",
        "language" => "en",
        "has_mature_content" => false,
        "category" => %{"id" => 15, "name" => "Just Chatting"},
        "Category" => %{"id" => 15, "name" => "Just Chatting"}
      }
    }

    assert Changes.from_event(body) ==
             {snap("t"), %{id: 15, name: "Just Chatting"}}

    livestream = %{
      "stream_title" => "t",
      "category" => %{"id" => 15, "name" => "Just Chatting"},
      "language" => "en",
      "has_mature_content" => false
    }

    assert Changes.from_livestream(livestream) == Changes.from_event(body)
  end
end
