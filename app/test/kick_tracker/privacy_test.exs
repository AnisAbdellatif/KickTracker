defmodule KickTracker.PrivacyTest do
  @moduledoc "A deletion request removes what identifies a person and keeps the counts."

  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Events, Privacy}
  alias KickTracker.Events.Envelope
  alias KickTracker.TestKick

  @person 424_242
  @now ~U[2026-06-01 12:00:00.000000Z]

  test "scrub removes a person from any JSON, and only them" do
    body = %{
      "broadcaster" => TestKick.user(1, "somestreamer"),
      "gifter" => TestKick.user(@person, "someone"),
      "giftees" => [TestKick.user(7, "a"), TestKick.user(@person, "someone")],
      "ids" => [@person, 7]
    }

    s = Privacy.scrub(body, @person)
    assert s["broadcaster"] == body["broadcaster"]

    assert %{"user_id" => nil, "username" => "[redacted]", "channel_slug" => "[redacted]"} =
             s["gifter"]

    assert Enum.at(s["giftees"], 0) == TestKick.user(7, "a")
    assert s["ids"] == [7]
    refute Jason.encode!(s) =~ "someone"
  end

  test "find and delete: chat rows and the username go, follows and gifts stay counted" do
    c = channel!()
    b = TestKick.user(c.kick_user_id, "somestreamer")

    envelopes =
      for {type, body} <- [
            {"channel.followed",
             %{"broadcaster" => b, "follower" => TestKick.user(@person, "someone")}},
            {"channel.subscription.gifts",
             %{
               "broadcaster" => b,
               "gifter" => TestKick.user(@person, "someone"),
               "giftees" => [TestKick.user(8, "x")],
               "created_at" => "2026-03-02T20:00:00Z"
             }}
          ] do
        {:ok, e} = TestKick.message(type, body) |> Envelope.decode()
        e
      end

    {:ok, _} = Events.ingest(envelopes)
    s = stream!(c, ~U[2026-03-02 20:00:00Z], ~U[2026-03-02 21:00:00Z])

    Repo.insert_all("chat_stream_users", [
      %{
        stream_id: s,
        user_id: @person,
        messages: 3,
        first_at: ~U[2026-03-02 20:01:00Z],
        last_at: ~U[2026-03-02 20:02:00Z]
      }
    ])

    Repo.insert_all("chat_minute_users", [
      %{channel_id: c.id, minute: ~U[2026-03-02 20:01:00Z], user_id: @person, messages: 3}
    ])

    found = Privacy.find(@person)
    assert found.username == "someone"

    assert %{chat_minutes: 1, chat_streams: 1, follows: 1, support_events: 1, webhook_events: 2} =
             found

    Privacy.delete(@person)

    after_ = Privacy.find(@person)

    assert %{
             username: nil,
             chat_minutes: 0,
             chat_streams: 0,
             follows: 0,
             support_events: 0,
             webhook_events: 0
           } = after_

    # Still counted, without the person.
    assert [%{user_id: nil}] = rows("follows", ["message_id"])
    assert [%{user_id: nil, kind: "gift"}] = rows("support_events", ["message_id"])

    bodies = rows("webhook_events", ["message_id"])
    assert Enum.all?(bodies, &(&1.redacted_at != nil))
    refute Enum.any?(bodies, &(&1.body =~ "someone"))
    # Someone else named in the same event is untouched.
    assert Enum.any?(bodies, &(&1.body =~ "\"x\""))
  end

  test "hosts to or from the person lose their name; the hosts and their viewers stay" do
    c = channel!()
    Repo.insert_all("kick_users", [%{id: @person, username: "someone", seen_at: @now}])

    rows = [
      # Hosted by them (named by username, in Kick's case), then hosting them.
      KickTracker.ChannelEvents.row(
        "App\\Events\\StreamHostEvent",
        "chatrooms.1.v2",
        %{"host_username" => "SomeOne", "number_viewers" => 12},
        @now
      ),
      KickTracker.ChannelEvents.row(
        "App\\Events\\ChatMoveToSupportedChannelEvent",
        "channel.1",
        %{
          "slug" => "someone",
          "hosted" => %{"slug" => "someone", "username" => "SomeOne", "viewers_count" => 12}
        },
        DateTime.add(@now, 60)
      ),
      KickTracker.ChannelEvents.row(
        "App\\Events\\StreamHostEvent",
        "chatrooms.1.v2",
        %{"host_username" => "someone_else", "number_viewers" => 3},
        DateTime.add(@now, 120)
      )
    ]

    for row <- rows,
        do: :ok = KickTracker.Stats.insert_channel_event(Map.put(row, :channel_id, c.id))

    assert Privacy.find(@person).channel_events == 2
    assert %{channel_events: 2} = Privacy.delete(@person)

    assert [
             %{kind: "hosted_by", other_channel: nil, viewers: 12} = by,
             %{kind: "hosting", other_channel: nil, viewers: 12} = to,
             %{other_channel: "someone_else", viewers: 3}
           ] = rows("channel_events", ["occurred_at"])

    refute Jason.encode!([by.payload, to.payload]) =~ ~r/someone/i
    assert Privacy.find(@person).channel_events == 0
  end

  test "logged messages go; replies to them no longer say whom they answered" do
    c = channel!()
    at = DateTime.utc_now()

    KickTracker.ChatLog.insert_messages(c.id, [
      KickTracker.ChatLog.message_row(%{id: "p1", sender_id: @person, at: at}, %{content: "mine"}),
      KickTracker.ChatLog.message_row(%{id: "o1", sender_id: 7, at: at}, %{
        content: "an answer",
        type: "reply",
        reply_to_message_id: "p1",
        reply_to_user_id: @person
      })
    ])

    KickTracker.ChatLog.insert_event(
      c.id,
      KickTracker.ChatLog.event_row("E", nil, %{"user" => TestKick.user(@person, "someone")}, at)
    )

    assert %{chat_messages: 1, chat_log_events: 1} = Privacy.find(@person)
    assert %{chat_messages: 1, chat_log_events: 1} = Privacy.delete(@person)

    assert [%{message_id: "o1", reply_to_user_id: nil}] = rows("chat_messages", ["message_id"])
    refute inspect(rows("chat_log_events", ["id"])) =~ "someone"
    assert %{chat_messages: 0, chat_log_events: 0} = Privacy.find(@person)
  end

  test "a deletion forgets whom earlier privacy searches named in the audit log" do
    Repo.insert_all("kick_users", [
      %{id: @person, username: "someone", seen_at: DateTime.utc_now()},
      %{id: 7, username: "someone_else", seen_at: DateTime.utc_now()}
    ])

    # As an older version logged them: the term searched for.
    for term <- ["Someone", "#{@person}", "someone_else"],
        do: KickTracker.Audit.log(nil, "privacy.find", term)

    KickTracker.Audit.log(nil, "channel.add", "somestreamer")

    assert %{audit_entries: 2} = Privacy.delete(@person)

    targets = KickTracker.Audit.recent() |> Enum.map(&{&1.action, &1.target}) |> Enum.sort()

    assert targets == [
             {"channel.add", "somestreamer"},
             {"privacy.find", nil},
             {"privacy.find", nil},
             {"privacy.find", "someone_else"}
           ]
  end
end
