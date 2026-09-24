defmodule Receiver.PublisherTest do
  @moduledoc "Against the development broker's `test` vhost (deploy/compose.dev.yml)."

  use ExUnit.Case, async: false

  alias Receiver.{Publisher, TestBroker}

  setup do
    TestBroker.purge()
    :ok
  end

  defp start(url, exchange \\ "kick.events") do
    start_supervised!({Publisher, url: url, exchange: exchange, confirm_timeout_ms: 2_000})
    wait_until(fn -> Publisher.connected?() end)
  end

  defp wait_until(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(20) && {:cont, false}
    end)
  end

  test "a confirmed publish is on the exchange, with the contract's properties" do
    assert start(TestBroker.receiver_url())
    observed = TestBroker.observe()

    assert :ok =
             Publisher.publish("channel.followed", ~s({"x":1}),
               content_type: "application/json",
               message_id: "m1",
               type: "channel.followed",
               timestamp: 1_790_000_000,
               persistent: true
             )

    assert {~s({"x":1}), meta} = TestBroker.next(observed)
    assert meta.routing_key == "channel.followed"
    assert meta.message_id == "m1"
    assert meta.type == "channel.followed"
    assert meta.content_type == "application/json"
    assert meta.persistent == true
  end

  test "while the broker is down it answers at once instead of waiting" do
    start_supervised!({Publisher, url: TestBroker.dead_url(), exchange: "kick.events"})
    refute Publisher.connected?()

    {micros, result} = :timer.tc(fn -> Publisher.publish("k", "p", message_id: "m1") end)
    assert result == {:error, :not_connected}
    assert micros < 100_000
  end

  test "a message nothing would receive is reported, not silently confirmed" do
    chan = TestBroker.admin_channel()
    exchange = "test.unbound.#{System.unique_integer([:positive])}"
    :ok = AMQP.Exchange.declare(chan, exchange, :topic, auto_delete: true)

    # Admin, because the receiver user may only publish to kick.events.
    assert start(TestBroker.admin_url(), exchange)

    assert Publisher.publish("channel.followed", "p", message_id: "m-unroutable") ==
             {:error, :unroutable}

    # And it carries on working afterwards.
    assert Publisher.connected?()
  end

  test "the receiver's user may publish to kick.events only; refused, it reconnects" do
    assert start(TestBroker.receiver_url(), "somewhere.else")
    pid = Process.whereis(Publisher)

    assert {:error, {:channel_closed, _}} = Publisher.publish("k", "p", message_id: "m1")
    # Same process: the refusal was handled, not survived by a restart.
    assert Process.whereis(Publisher) == pid
    # The broker closes the channel on a permission error; it comes back.
    assert wait_until(fn -> Publisher.connected?() end)
  end

  test "it reconnects on its own after losing the connection" do
    assert start(TestBroker.receiver_url())
    %{conn: conn} = :sys.get_state(Publisher)

    AMQP.Connection.close(conn)

    assert wait_until(fn ->
             %{conn: new} = :sys.get_state(Publisher)
             new != nil and new != conn
           end)

    observed = TestBroker.observe()
    assert :ok = Publisher.publish("channel.followed", "after", message_id: "m2")
    assert {"after", _} = TestBroker.next(observed)
  end
end
