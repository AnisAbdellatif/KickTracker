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
    wait_until(fn -> TestBroker.depth("kick_tracker.events.dead") >= 1 end)
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
    assert DeadLetters.count() == {:ok, 2}
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
end
