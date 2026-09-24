defmodule KickTracker.Events.IngestTest do
  @moduledoc "Facts are written with the event, once, and only for tracked channels."

  use KickTracker.DataCase, async: true

  import KickTracker.Fixtures
  alias KickTracker.Events
  alias KickTracker.Events.Envelope
  alias KickTracker.TestKick

  defp envelope(type, body, opts \\ []) do
    {:ok, e} = TestKick.message(type, body, opts) |> Envelope.decode()
    e
  end

  test "a follow and a gift for a tracked channel become rows, usernames only in kick_users" do
    c = channel!()
    b = TestKick.user(c.kick_user_id, "somestreamer")

    follow =
      envelope("channel.followed", %{"broadcaster" => b, "follower" => TestKick.user(11, "fan")})

    gift =
      envelope("channel.subscription.gifts", %{
        "broadcaster" => b,
        "gifter" => TestKick.user(12, "gifter"),
        "giftees" => [TestKick.user(13, "a"), TestKick.user(14, "b")],
        "created_at" => "2026-09-24T18:00:00Z"
      })

    assert {:ok, [_, _]} = Events.ingest([follow, gift])
    # A repeat changes nothing.
    assert {:ok, []} = Events.ingest([follow, gift])

    assert [%{user_id: 11, channel_id: id}] = rows("follows", ["message_id"])
    assert id == c.id
    assert [%{kind: "gift", quantity: 2, user_id: 12}] = rows("support_events", ["message_id"])

    assert rows("kick_users", ["id"]) |> Enum.map(&{&1.id, &1.username}) ==
             [{11, "fan"}, {12, "gifter"}, {13, "a"}, {14, "b"}]

    assert Enum.all?(rows("webhook_events", ["message_id"]), & &1.processed_at)
  end

  test "an event for a channel we don't track is stored and processed, with no facts" do
    e =
      envelope("channel.followed", %{
        "broadcaster" => TestKick.user(99_999),
        "follower" => TestKick.user(11)
      })

    assert {:ok, [_]} = Events.ingest([e])
    assert rows("follows", ["message_id"]) == []
    assert [%{processed_at: %DateTime{}}] = rows("webhook_events", ["message_id"])
  end

  test "a later username replaces an earlier one; an older sighting arriving late doesn't" do
    c = channel!()
    b = TestKick.user(c.kick_user_id)

    follow = fn name, sent_at ->
      envelope("channel.followed", %{"broadcaster" => b, "follower" => TestKick.user(11, name)},
        sent_at: sent_at
      )
    end

    Events.ingest([follow.("newname", "2026-09-24T19:00:00Z")])
    Events.ingest([follow.("oldname", "2026-09-24T18:00:00Z")])
    assert [%{username: "newname"}] = rows("kick_users", ["id"])
  end
end
