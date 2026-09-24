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

  describe "reconnecting" do
    setup do
      name = "receiver-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> TestBroker.close_connections(name) end)
      %{name: name}
    end

    defp start_named(name, url \\ TestBroker.receiver_url()) do
      start_supervised!({Publisher, url: url, exchange: "kick.events", connection_name: name})

      wait_until(fn -> Publisher.connected?() end, 250)
    end

    # The management API lists a new connection only at its next stats
    # emission (every 5s), a closed one at once: wait for ours to show, then
    # a full period more, so any extra one would have shown up too.
    defp settles_on_one_connection?(name) do
      wait_until(fn -> TestBroker.connections(name) != [] end, 500) and
        Process.sleep(5_500) == :ok and
        length(TestBroker.connections(name)) == 1
    end

    test "killing the connection again and again leaves exactly one", %{name: name} do
      assert start_named(name)

      for _ <- 1..4 do
        %{conn: conn} = :sys.get_state(Publisher)
        Process.exit(conn.pid, :kill)

        assert wait_until(
                 fn ->
                   match?(%{conn: %{pid: pid}} when pid != conn.pid, :sys.get_state(Publisher))
                 end,
                 250
               )
      end

      assert settles_on_one_connection?(name)
      assert Publisher.connected?()
    end

    test "the broker closing it several times leaves exactly one", %{name: name} do
      assert start_named(name)

      for _ <- 1..3 do
        assert wait_until(fn -> length(TestBroker.connections(name)) == 1 end, 500)
        TestBroker.close_connections(name)
        assert wait_until(fn -> not Publisher.connected?() end, 250)
        assert wait_until(fn -> Publisher.connected?() end, 250)
      end

      assert settles_on_one_connection?(name)
      observed = TestBroker.observe()
      assert :ok = Publisher.publish("channel.followed", "after", message_id: "m-after")
      assert {"after", _} = TestBroker.next(observed)
    end

    test "a stale DOWN or an extra connect doesn't open a second connection", %{name: name} do
      assert start_named(name)
      pid = Process.whereis(Publisher)

      send(pid, {:DOWN, make_ref(), :process, self(), :old})
      send(pid, {:connect, make_ref()})

      assert settles_on_one_connection?(name)
    end

    test "stopping it closes its connection", %{name: name} do
      assert start_named(name)
      assert wait_until(fn -> length(TestBroker.connections(name)) == 1 end, 500)
      stop_supervised!(Publisher)
      assert wait_until(fn -> TestBroker.connections(name) == [] end, 250)
    end
  end

  describe "a broker that doesn't confirm" do
    # Stands in for a broker that has stopped answering (an alarm, a stuck
    # queue): the confirm never comes before the timeout.
    defp slow_confirm(test, sleep_ms) do
      fn _chan, timeout_ms ->
        send(test, {:confirm_wait, timeout_ms})
        Process.sleep(min(sleep_ms, timeout_ms))
        :timeout
      end
    end

    test "gives up after the confirm timeout, in milliseconds, and stays answerable" do
      start_supervised!(
        {Publisher,
         url: TestBroker.receiver_url(),
         exchange: "kick.events",
         confirm_timeout_ms: 300,
         confirm: slow_confirm(self(), 10_000)}
      )

      assert wait_until(fn -> Publisher.connected?() end)

      task =
        Task.async(fn -> :timer.tc(fn -> Publisher.publish("k", "p", message_id: "m") end) end)

      assert_receive {:confirm_wait, wait_ms}, 1_000
      assert wait_ms <= 300

      # While it waits, asking whether it is connected doesn't.
      {micros, true} = :timer.tc(fn -> Publisher.connected?() end)
      assert micros < 50_000

      {micros, result} = Task.await(task)
      assert result == {:error, :confirm_timeout}
      assert micros < 1_000_000
    end

    test "a caller gives up at confirm timeout plus a second, and its request is dropped" do
      start_supervised!(
        {Publisher,
         url: TestBroker.receiver_url(),
         exchange: "kick.events",
         confirm_timeout_ms: 1_500,
         confirm: slow_confirm(self(), 1_500)}
      )

      assert wait_until(fn -> Publisher.connected?() end)
      observed = TestBroker.observe()

      first =
        Task.async(fn -> Publisher.publish("channel.followed", "first", message_id: "m1") end)

      assert_receive {:confirm_wait, _}, 1_000

      # Queued behind the stuck publish; its caller stops waiting first.
      {micros, result} =
        :timer.tc(fn ->
          Publisher.publish("channel.followed", "second", [message_id: "m2"], Publisher,
            timeout: 200
          )
        end)

      assert {:error, {:publisher_unavailable, _}} = result
      assert micros < 500_000
      assert Task.await(first) == {:error, :confirm_timeout}

      # The first was published (and will be spooled too: harmless); the
      # second, given up on, never was.
      assert {"first", _} = TestBroker.next(observed)
      assert TestBroker.next(observed, 500) == nil
      refute_received {:confirm_wait, _}
    end
  end

  test "while RabbitMQ blocks publishers it answers at once, then resumes" do
    assert start(TestBroker.receiver_url())
    pid = Process.whereis(Publisher)

    send(pid, {:"connection.blocked", "low on memory"})
    assert wait_until(fn -> not Publisher.connected?() end)

    assert Publisher.publish("channel.followed", "p", message_id: "m-blocked") ==
             {:error, :blocked}

    send(pid, {:"connection.unblocked"})
    assert wait_until(fn -> Publisher.connected?() end)
    observed = TestBroker.observe()
    assert :ok = Publisher.publish("channel.followed", "again", message_id: "m-unblocked")
    assert {"again", _} = TestBroker.next(observed)
  end

  test "status says for how long it has been disconnected" do
    start_supervised!({Publisher, url: TestBroker.dead_url(), exchange: "kick.events"})
    Process.sleep(100)

    assert %{connected: false, disconnected_for_ms: ms} = Publisher.status()
    assert ms >= 100
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
