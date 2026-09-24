defmodule KickTracker.PrivacyTest do
  @moduledoc "A deletion request removes what identifies a person and keeps the counts."

  use KickTracker.DataCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Events, Privacy}
  alias KickTracker.Events.Envelope
  alias KickTracker.TestKick

  @person 424_242

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
