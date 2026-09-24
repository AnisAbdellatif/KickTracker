defmodule KickTracker.Stats.ChatTest do
  # Not async: writes hypertables (see StatsTest).
  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.Stats

  @m ~U[2026-01-05 20:00:00.000000Z]

  defp u(messages, first, last),
    do: %{messages: messages, first_at: DateTime.add(@m, first), last_at: DateTime.add(@m, last)}

  test "minutes, their chatters, and per-stream totals; a late message is added, not doubled" do
    c = channel!()
    stream = Stats.apply_stream(c.id, {:open, ~U[2026-01-05 19:00:00.000000Z]})

    Stats.write_chat(c.id, [
      %{minute: @m, stream_id: stream, users: %{1 => u(2, 1, 30), 2 => u(1, 10, 10)}},
      %{minute: DateTime.add(@m, 60), stream_id: stream, users: %{1 => u(1, 65, 65)}}
    ])

    # A message that arrived after its minute was written.
    Stats.write_chat(c.id, [
      %{minute: @m, stream_id: stream, users: %{3 => u(1, 50, 50), 1 => u(1, 40, 40)}}
    ])

    assert [%{messages: 5, chatters: 3, stream_id: ^stream}, %{messages: 1, chatters: 1}] =
             rows("chat_minutes", ["minute"])

    assert [%{user_id: 1, messages: 4, first_at: f, last_at: l}, %{user_id: 2}, %{user_id: 3}] =
             rows("chat_stream_users", ["user_id"])

    assert {f, l} == {DateTime.add(@m, 1), DateTime.add(@m, 65)}
  end

  test "offline chat is counted, with no stream" do
    c = channel!()
    Stats.write_chat(c.id, [%{minute: @m, stream_id: nil, users: %{1 => u(1, 1, 1)}}])
    assert [%{stream_id: nil, messages: 1}] = rows("chat_minutes", ["minute"])
    assert rows("chat_stream_users", ["user_id"]) == []
  end

  test "chat_minute_users is dropped after 90 days" do
    %{rows: [[config]]} =
      Repo.query!(
        "SELECT config FROM timescaledb_information.jobs WHERE hypertable_name = 'chat_minute_users' AND proc_name = 'policy_retention'"
      )

    assert config["drop_after"] =~ "90 days"
  end
end
