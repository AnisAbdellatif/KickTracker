defmodule KickTracker.Events.FactsTest do
  @moduledoc """
  Facts from event bodies: the recorded follows, and for subs, gifts and
  Kicks (not recorded yet) the simulator's documentation-based shapes.
  """

  use ExUnit.Case, async: true

  import KickTracker.Fixtures
  alias KickTracker.Events.{Envelope, Facts}
  alias KickTracker.TestKick

  defp envelope(type, body, sent_at \\ "2026-09-24T18:02:11Z") do
    {:ok, e} = TestKick.message(type, body, sent_at: sent_at) |> Envelope.decode()
    e
  end

  defp sim_channel, do: Sim.Scenario.Channel.new(slug: "somestreamer")
  @at ~U[2026-09-24 18:00:00Z]

  test "every recorded follow parses, dated by the delivery (the body has no time)" do
    recorded = recorded_webhooks("channel.followed")
    assert recorded != []

    for {body, sent_at} <- recorded do
      e = envelope("channel.followed", body, sent_at)
      assert {{:follow, row}, [%{id: id, username: name}]} = Facts.parse(e, 1)
      assert row.user_id == id and is_binary(name)
      assert row.occurred_at == e.occurred_at
      assert row.channel_id == 1
    end
  end

  test "new subs: the subscriber, months, and the body's own time" do
    body = Sim.Payloads.subscription(sim_channel(), 42, 1, @at)

    assert {{:support, row}, [%{id: 42}]} =
             Facts.parse(envelope("channel.subscription.new", body), 1)

    assert %{kind: "sub", user_id: 42, quantity: 1, tier: nil} = row
    assert row.occurred_at == ~U[2026-09-24 18:00:00.000000Z]
    assert %{"expires_at" => _} = row.payload
  end

  test "resubs are dated by the delivery, not by created_at (when the subscription started)" do
    # Twenty-two months in: created_at is back in 2024. It used to be the
    # resub's time, which put it in periods before the channel was
    # tracked, so a longer period showed more resubs than "all".
    body = Sim.Payloads.renewal(sim_channel(), 42, 22, @at)
    assert body["created_at"] =~ ~r/^2024-/

    e = envelope("channel.subscription.renewal", body, "2026-09-24T18:00:05Z")
    assert {{:support, row}, [%{id: 42}]} = Facts.parse(e, 1)

    assert %{kind: "resub", user_id: 42, quantity: 22, tier: nil} = row
    assert row.occurred_at == e.occurred_at
    assert DateTime.compare(row.occurred_at, ~U[2026-09-24 18:00:05Z]) == :eq
    assert %{"expires_at" => _} = row.payload
  end

  test "gifts: the gifter, how many, and who received them; anonymous gifters have no id" do
    body = Sim.Payloads.subscription_gifts(sim_channel(), 7, [8, 9, 10], @at)
    assert {{:support, row}, users} = Facts.parse(envelope("channel.subscription.gifts", body), 1)
    assert %{kind: "gift", user_id: 7, quantity: 3} = row
    assert row.payload["giftee_ids"] == [8, 9, 10]
    assert Enum.map(users, & &1.id) == [7, 8, 9, 10]

    body = Sim.Payloads.subscription_gifts(sim_channel(), nil, [8], @at)

    assert {{:support, row}, [%{id: 8}]} =
             Facts.parse(envelope("channel.subscription.gifts", body), 1)

    assert %{user_id: nil, quantity: 1} = row
    assert row.payload["anonymous"] == true
  end

  test "Kicks: amount and tier, and never the sender's message" do
    body =
      Sim.Payloads.kicks_gifted(sim_channel(), 5, 100, @at)
      |> put_in(["gift", "message"], "some text")

    assert {{:support, row}, [%{id: 5}]} = Facts.parse(envelope("kicks.gifted", body), 1)
    assert %{kind: "kicks", quantity: 100, tier: "epic"} = row
    refute inspect(row) =~ "some text"
  end

  test "a body missing what the fact needs is no fact" do
    assert Facts.parse(envelope("channel.followed", %{"broadcaster" => %{}}), 1) == :none
    assert Facts.parse(envelope("kicks.gifted", %{"gift" => %{"amount" => 0}}), 1) == :none
    assert Facts.parse(envelope("channel.subscription.gifts", %{"giftees" => []}), 1) == :none
    assert Facts.parse(envelope("channel.followed", "not json"), 1) == :none
  end
end
