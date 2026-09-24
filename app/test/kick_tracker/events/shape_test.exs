defmodule KickTracker.Events.ShapeTest do
  use KickTracker.DataCase, async: true

  import KickTracker.Fixtures
  alias KickTracker.Events
  alias KickTracker.Events.{Envelope, Shape}
  alias KickTracker.TestKick

  defp envelope(type, body, opts \\ []) do
    {:ok, e} = TestKick.message(type, body, opts) |> Envelope.decode()
    e
  end

  test "every recorded webhook has the shape we parse" do
    for type <- ~w(livestream.status.updated livestream.metadata.updated channel.followed),
        {body, _at} <- recorded_webhooks(type) do
      e = envelope(type, Jason.decode!(body))
      assert Shape.check(e) == [], "#{type}: #{inspect(Shape.check(e))}"
    end
  end

  test "a missing field, a changed type, an unknown version or type are named" do
    b = TestKick.user(1, "somestreamer")

    assert Shape.check(envelope("channel.followed", %{"broadcaster" => b})) == [
             "follower.user_id is not an integer"
           ]

    assert Shape.check(
             envelope("kicks.gifted", %{"broadcaster" => b, "gift" => %{"amount" => "100"}})
           ) ==
             ["gift.amount is not an integer"]

    assert Shape.check(envelope("channel.followed", %{"broadcaster" => b}, event_version: "2")) ==
             ["unknown version 2"]

    assert Shape.check(envelope("channel.something.new", %{"broadcaster" => b})) == [
             "unknown event type"
           ]

    assert Shape.check(envelope("channel.followed", %{"broadcaster" => "nope"})) == [
             "unexpected nesting"
           ]
  end

  test "problems are counted once per kind as events are stored, and still stored" do
    c = channel!()
    b = TestKick.user(c.kick_user_id, "somestreamer")

    bad =
      for _ <- 1..3,
          do: envelope("channel.followed", %{"broadcaster" => b, "follower" => %{"id" => 5}})

    assert {:ok, [_, _, _]} = Events.ingest(bad)

    assert {:ok, [_]} =
             Events.ingest([
               envelope("channel.followed", %{"broadcaster" => b, "follower" => %{"id" => 6}})
             ])

    assert [%{problem: "follower.user_id is not an integer", count: 4}] =
             rows("payload_issues", ["id"])

    assert length(rows("webhook_events", ["message_id"])) == 4
  end
end
