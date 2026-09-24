defmodule KickTracker.DeadLettersTest do
  @moduledoc "Dead letters are listed without being consumed, replayed with confirms, or discarded."

  use ExUnit.Case, async: false

  alias KickTracker.{DeadLetters, TestBroker}

  setup do
    TestBroker.purge()
    on_exit(&TestBroker.purge/0)
    :ok
  end

  # A message dead-lettered the way the consumer does it: rejected from the
  # main queue without requeue.
  defp dead_letter!(message_id, routing_key \\ "channel.followed") do
    # Dead-lettering into a quorum queue lands a moment later: wait for this
    # message, not just any.
    dead_before = TestBroker.depth("kick_tracker.events.dead")
    {:ok, conn} = AMQP.Connection.open(TestBroker.admin_url())
    {:ok, chan} = AMQP.Channel.open(conn)
    :ok = AMQP.Confirm.select(chan)

    :ok =
      AMQP.Basic.publish(chan, "kick.events", routing_key, ~s({"message_id":"#{message_id}"}),
        message_id: message_id,
        type: routing_key,
        persistent: true
      )

    true = AMQP.Confirm.wait_for_confirms(chan, 5_000)
    {:ok, _payload, meta} = wait_get(chan, "kick_tracker.events")
    :ok = AMQP.Basic.reject(chan, meta.delivery_tag, requeue: false)
    AMQP.Connection.close(conn)
    wait_until(fn -> TestBroker.depth("kick_tracker.events.dead") > dead_before end)
  end

  defp wait_get(chan, queue, tries \\ 50) do
    case AMQP.Basic.get(chan, queue) do
      {:empty, _} when tries > 0 ->
        Process.sleep(20)
        wait_get(chan, queue, tries - 1)

      other ->
        other
    end
  end

  defp wait_until(fun, tries \\ 100) do
    if fun.() or tries == 0,
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_until(fun, tries - 1)
        )
  end

  test "listing shows the message and leaves it in the queue" do
    dead_letter!("msg-1")
    dead_letter!("msg-2", "kicks.gifted")

    assert {:ok, [a, b]} = DeadLetters.list()

    assert a.message_id == "msg-1" and a.routing_key == "channel.followed" and
             a.reason == "rejected"

    assert b.event_type == "kicks.gifted" and b.envelope == %{"message_id" => "msg-2"}
    # Right after a listing, everything is back: counted, and can be acted on.
    assert DeadLetters.count() == {:ok, 2}
    assert :ok = DeadLetters.discard("msg-2")
    assert {:ok, [%{message_id: "msg-1"}]} = DeadLetters.list()
  end

  test "a replayed message goes back to the main queue and leaves the dead ones" do
    dead_letter!("msg-1")
    dead_letter!("msg-2")

    assert :ok = DeadLetters.replay("msg-2")
    assert TestBroker.depth("kick_tracker.events") == 1
    assert {:ok, [%{message_id: "msg-1"}]} = DeadLetters.list()
  end

  test "a discarded message is gone; an unknown id changes nothing" do
    dead_letter!("msg-1")
    assert DeadLetters.discard("nope") == {:error, :not_found}
    assert :ok = DeadLetters.discard("msg-1")
    assert DeadLetters.list() == {:ok, []}
    assert TestBroker.depth("kick_tracker.events") == 0
  end

  # Straight into the dead-letter queue through its exchange.
  defp publish_dead!(payloads) do
    dead_before = TestBroker.depth("kick_tracker.events.dead")
    {:ok, conn} = AMQP.Connection.open(TestBroker.admin_url())
    {:ok, chan} = AMQP.Channel.open(conn)
    :ok = AMQP.Confirm.select(chan)

    for {payload, opts} <- payloads,
        do: :ok = AMQP.Basic.publish(chan, "kick.events.dlx", "channel.followed", payload, opts)

    true = AMQP.Confirm.wait_for_confirms(chan, {5, :second})
    AMQP.Connection.close(conn)

    wait_until(fn ->
      TestBroker.depth("kick_tracker.events.dead") >= dead_before + length(payloads)
    end)
  end

  test "a message without a message id is named by its key" do
    publish_dead!([{"garbage", []}])
    assert {:ok, [m]} = DeadLetters.list()
    assert m.message_id == nil and m.key == DeadLetters.key(nil, "garbage")
    assert DeadLetters.discard(m.key) == :ok
    assert DeadLetters.list() == {:ok, []}
  end

  test "copies of one message are listed once and acted on together" do
    one = {~s({"a":1}), [message_id: "dup"]}
    publish_dead!([one, one, {~s({"b":2}), [message_id: "other"]}])

    assert {:ok, [%{message_id: "dup", copies: 2}, %{message_id: "other", copies: 1}]} =
             DeadLetters.list()

    assert :ok = DeadLetters.replay("dup")
    assert TestBroker.depth("kick_tracker.events") == 1
    assert {:ok, [%{message_id: "other"}]} = DeadLetters.list()
  end

  test "two different messages under one id are ambiguous until named by key" do
    publish_dead!([{"x", [message_id: "same"]}, {"y", [message_id: "same"]}])
    assert DeadLetters.discard("same") == {:error, :ambiguous}
    assert :ok = DeadLetters.discard(DeadLetters.key("same", "y"))
    assert {:ok, [%{payload: "x"}]} = DeadLetters.list()
  end

  test "a message past the first page listed can still be acted on" do
    publish_dead!(for i <- 1..205, do: {"m#{i}", [message_id: "m#{i}"]})
    assert {:ok, listed} = DeadLetters.list(500)
    assert length(listed) == 200
    refute Enum.any?(listed, &(&1.message_id == "m205"))

    assert :ok = DeadLetters.discard("m205")
    assert DeadLetters.count() == {:ok, 204}
  end

  describe "a message naming someone removed on request" do
    setup tags do
      KickTracker.DataCase.setup_sandbox(tags)
    end

    test "is shown redacted and can't be replayed, only discarded" do
      KickTracker.Removals.record(:user, 424_242)

      body =
        Jason.encode!(%{
          "follower" => %{"user_id" => 424_242, "username" => "someone"},
          "broadcaster" => %{"user_id" => 1, "username" => "somestreamer"}
        })

      envelope = Jason.encode!(%{"message_id" => "erased-1", "body" => body})
      publish_dead!([{envelope, [message_id: "erased-1"]}])

      assert {:ok, [m]} = DeadLetters.list()
      assert m.erased == [424_242]
      refute m.envelope["body"] =~ "someone"
      assert m.envelope["body"] =~ "somestreamer"

      assert DeadLetters.replay("erased-1") == {:error, :erased}
      assert TestBroker.depth("kick_tracker.events") == 0
      assert :ok = DeadLetters.discard("erased-1")
      assert DeadLetters.list() == {:ok, []}
    end
  end
end
