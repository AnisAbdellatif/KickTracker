defmodule KickTracker.ChatLogTest do
  @moduledoc "Chat logging's rows, retention, deletions and reads (project.md §12.8)."

  use KickTracker.DataCase, async: true

  import KickTracker.Fixtures
  alias KickTracker.ChatLog

  @now ~U[2026-06-01 12:00:00.000000Z]

  defp at(days_ago), do: DateTime.add(@now, -days_ago, :day)

  defp message(id, user, sent_at, content \\ "hi"),
    do:
      ChatLog.message_row(%{id: id, sender_id: user, at: sent_at}, %{
        content: content,
        type: "message",
        reply_to_message_id: nil,
        reply_to_user_id: nil
      })

  describe "rows" do
    test "a message keeps its text and what it replies to" do
      row =
        ChatLog.message_row(%{id: "m1", sender_id: 7, at: @now}, %{
          content: "hello",
          type: "reply",
          reply_to_message_id: "m0",
          reply_to_user_id: 8
        })

      assert row == %{
               sent_at: @now,
               message_id: "m1",
               user_id: 7,
               type: "reply",
               content: "hello",
               reply_to_message_id: "m0",
               reply_to_user_id: 8
             }
    end

    test "a message without an id is keyed on what it is" do
      a = ChatLog.message_row(%{sender_id: 7, at: @now}, %{content: "x"})

      assert a.message_id ==
               ChatLog.message_row(%{sender_id: 7, at: @now}, %{content: "x"}).message_id

      refute a.message_id ==
               ChatLog.message_row(%{sender_id: 7, at: @now}, %{content: "y"}).message_id
    end

    test "an event is kept as sent; the same one at the same time has the same key" do
      row = ChatLog.event_row("App\\Events\\UserBannedEvent", "chatrooms.1.v2", %{"a" => 1}, @now)
      assert %{event: "App\\Events\\UserBannedEvent", payload: %{"data" => %{"a" => 1}}} = row

      assert row.dedup_key ==
               ChatLog.event_row(row.event, row.pusher_channel, %{"a" => 1}, @now).dedup_key

      refute row.dedup_key ==
               ChatLog.event_row(row.event, row.pusher_channel, %{"a" => 2}, @now).dedup_key
    end
  end

  describe "storage" do
    test "a message stored twice is kept once" do
      c = channel!()
      ChatLog.insert_messages(c.id, [message("m1", 7, @now)])
      ChatLog.insert_messages(c.id, [message("m1", 7, @now), message("m2", 7, @now)])
      assert length(rows("chat_messages", ["message_id"])) == 2
    end

    test "each channel's retention is its own; logging off keeps its log until then" do
      short = channel!()
      long = channel!()
      {:ok, short} = ChatLog.configure(short, false, 7)
      {:ok, _} = ChatLog.configure(long, true, 90)

      for c <- [short, long] do
        ChatLog.insert_messages(c.id, [message("old", 7, at(30)), message("new", 7, at(1))])
        ChatLog.insert_event(c.id, ChatLog.event_row("E", nil, %{}, at(30)))
      end

      assert ChatLog.prune(@now) == %{messages: 1, events: 1}

      assert rows("chat_messages", ["channel_id", "message_id"])
             |> Enum.map(&{&1.channel_id, &1.message_id}) ==
               Enum.sort([{short.id, "new"}, {long.id, "new"}, {long.id, "old"}])
    end

    test "an admin's deletion takes one channel's log over one period" do
      c = channel!()
      other = channel!()

      for ch <- [c, other],
          do:
            ChatLog.insert_messages(ch.id, [
              message("a", 7, at(3)),
              message("b", 7, at(2)),
              message("c", 7, at(1))
            ])

      ChatLog.insert_event(c.id, ChatLog.event_row("E", nil, %{}, at(2)))

      assert ChatLog.delete_range(c.id, at(2), at(1)) == %{messages: 1, events: 1}
      assert Enum.map(ChatLog.messages(%{channel_ids: [c.id]}), & &1.message_id) == ["c", "a"]
      assert length(ChatLog.messages(%{channel_ids: [other.id]})) == 3
    end

    test "retention is bounded" do
      c = channel!()
      assert ChatLog.configure(c, true, 0) == {:error, :bad_retention}

      assert ChatLog.configure(c, true, ChatLog.max_retention_days() + 1) ==
               {:error, :bad_retention}
    end
  end

  describe "reads" do
    test "by channel, by user across channels, by period, a page at a time, with usernames" do
      a = channel!(slug: "somestreamer")
      b = channel!(slug: "otherstreamer")
      Repo.insert_all("kick_users", [%{id: 7, username: "someone", seen_at: @now}])

      ChatLog.insert_messages(a.id, [message("a1", 7, at(3)), message("a2", 8, at(2))])
      ChatLog.insert_messages(b.id, [message("b1", 7, at(1))])

      assert [
               %{message_id: "b1", slug: "otherstreamer", username: "someone"},
               %{message_id: "a1"}
             ] =
               ChatLog.messages(%{user_ids: ChatLog.find_users("SomeOne")})

      assert Enum.map(ChatLog.messages(%{channel_ids: [a.id]}), & &1.message_id) == ["a2", "a1"]

      assert Enum.map(ChatLog.messages(%{from: at(2), to: at(0)}), & &1.message_id) == [
               "b1",
               "a2"
             ]

      [first] = ChatLog.messages(%{limit: 1})
      [second] = ChatLog.messages(%{limit: 1, before: {first.sent_at, first.message_id}})
      assert {first.message_id, second.message_id} == {"b1", "a2"}

      assert ChatLog.find_users("8") == [8]
    end
  end
end
