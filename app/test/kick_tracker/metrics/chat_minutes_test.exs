defmodule KickTracker.Metrics.ChatMinutesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Metrics.ChatMinutes

  @t ~U[2026-01-05 20:00:00.000000Z]
  defp at(s), do: DateTime.add(@t, s)
  defp msg(id, sender, s), do: %{id: id, sender_id: sender, username: "user#{sender}", at: at(s)}

  test "messages count in their own minute, by sender; a minute is handed out once over" do
    chat =
      Enum.reduce(
        [msg("a", 1, 5), msg("b", 1, 30), msg("c", 2, 59), msg("d", 1, 61)],
        ChatMinutes.new(),
        &ChatMinutes.add(&2, &1)
      )

    # 60s after the minute's end is still inside the settle time.
    {[], [], chat} = ChatMinutes.take_done(chat, at(60 + 20))
    {[m], users, chat} = ChatMinutes.take_done(chat, at(60 + 31))

    assert m.minute == at(0)
    assert m.users[1].messages == 2 and m.users[2].messages == 1
    assert m.users[1].first_at == at(5) and m.users[1].last_at == at(30)
    # A name is recorded with its latest sighting.
    assert Enum.sort(users) == [{1, "user1", at(61)}, {2, "user2", at(59)}]

    assert {[%{minute: second}], _, _} = ChatMinutes.take_done(chat, at(200))
    assert second == at(60)
  end

  test "the same message id counts once" do
    chat = ChatMinutes.new() |> ChatMinutes.add(msg("a", 1, 5)) |> ChatMinutes.add(msg("a", 1, 5))
    {[m], _, _} = ChatMinutes.take_done(chat, at(600))
    assert m.users[1].messages == 1
  end

  property "any order gives the same minutes: totals and distinct chatters" do
    check all(
            messages <-
              list_of(tuple({integer(1..5), integer(0..299)}), max_length: 200)
              |> map(fn l -> Enum.with_index(l, fn {s, t}, i -> msg("m#{i}", s, t) end) end),
            shuffled <- constant(messages) |> map(&Enum.shuffle/1)
          ) do
      summary = fn msgs ->
        chat = Enum.reduce(msgs, ChatMinutes.new(), &ChatMinutes.add(&2, &1))
        {minutes, _, _} = ChatMinutes.take_done(chat, at(10_000))

        Enum.map(minutes, fn m ->
          {m.minute, Enum.sort(Enum.map(m.users, fn {u, x} -> {u, x.messages} end))}
        end)
      end

      assert summary.(messages) == summary.(shuffled)

      total = summary.(messages) |> Enum.flat_map(&elem(&1, 1)) |> Enum.sum_by(&elem(&1, 1))
      assert total == length(messages)
    end
  end
end
