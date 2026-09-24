defmodule KickTracker.StatsTest do
  @moduledoc "The stream upserts keep the sessionizer's rules in SQL too."

  # Not async: tests writing hypertables create chunks inside their
  # sandbox transactions, and concurrent chunk creation deadlocks.
  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.Stats

  @s ~U[2026-01-05 20:00:00.000000Z]
  defp at(s), do: DateTime.add(@s, s)

  setup do: %{c: channel!()}

  defp stream(c), do: rows("streams", ["id"]) |> Enum.filter(&(&1.channel_id == c.id))

  test "open is idempotent and returns the same id", %{c: c} do
    id = Stats.apply_stream(c.id, {:open, @s})
    assert Stats.apply_stream(c.id, {:open, @s}) == id
    assert [%{ended_at: nil}] = stream(c)
  end

  test "an end from the event always wins; a poll end only moves later", %{c: c} do
    id = Stats.apply_stream(c.id, {:open, @s})

    assert Stats.apply_stream(c.id, {:close, @s, at(600), :poll}) == id
    Stats.apply_stream(c.id, {:close, @s, at(300), :poll})
    assert [%{ended_at: t, end_source: "poll"}] = stream(c)
    assert t == at(600)

    Stats.apply_stream(c.id, {:close, @s, at(500), :event})
    Stats.apply_stream(c.id, {:close, @s, at(900), :poll})
    assert [%{ended_at: t, end_source: "event"}] = stream(c)
    assert t == at(500)
  end

  test "only a stream closed from polling can reopen", %{c: c} do
    Stats.apply_stream(c.id, {:close, @s, at(600), :poll})
    Stats.apply_stream(c.id, {:reopen, @s})
    assert [%{ended_at: nil, end_source: nil}] = stream(c)

    Stats.apply_stream(c.id, {:close, @s, at(700), :event})
    Stats.apply_stream(c.id, {:reopen, @s})
    assert [%{end_source: "event"}] = stream(c)
  end

  test "a closed stream never seen open is inserted closed", %{c: c} do
    Stats.apply_stream(c.id, {:close, @s, at(60), :event})
    assert [%{end_source: "event"}] = stream(c)
  end

  test "recent streams carry their latest sample time", %{c: c} do
    id = Stats.apply_stream(c.id, {:open, @s})

    for s <- [60, 120] do
      Stats.insert_viewer_sample(%{
        channel_id: c.id,
        observed_at: at(s),
        stream_id: id,
        viewers: 5,
        category_id: nil
      })
    end

    assert [%{id: ^id, last_live_at: last}] = Stats.recent_streams(c.id)
    assert last == at(120)
  end

  test "a stream's current values come from its change log", %{c: c} do
    id = Stats.apply_stream(c.id, {:open, @s})

    Stats.insert_changes(id, [
      %{field: "title", old_value: nil, new_value: "a", occurred_at: at(1), source: :event},
      %{field: "title", old_value: "a", new_value: "b", occurred_at: at(60), source: :event},
      %{field: "category", old_value: nil, new_value: "15", occurred_at: at(1), source: :event}
    ])

    # The same change again (a replay) is stored once.
    Stats.insert_changes(id, [
      %{field: "title", old_value: "a", new_value: "b", occurred_at: at(60), source: :event}
    ])

    assert Stats.current_values(id) == {%{"title" => "b", "category" => "15"}, at(60)}
    assert length(rows("stream_changes", ["id"])) == 3
  end
end
