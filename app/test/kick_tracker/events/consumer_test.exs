defmodule KickTracker.Events.ConsumerTest do
  @moduledoc """
  The consumer's promises (project.md §8.2, §10): every good envelope
  stored once, acknowledged after the commit; anything that can't be
  decoded or verified dead-lettered, never retried in a loop; stream
  events handed to their channel only once stored.
  """

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  alias KickTracker.Events.{Consumer, WebhookEvent}
  alias KickTracker.Kick.PublicKey
  alias KickTracker.TestKick

  @follow ~s({"broadcaster":{"user_id":7},"follower":{"user_id":8}})
  @status ~s({"broadcaster":{"user_id":7},"is_live":true,"title":"t","started_at":"2026-09-24T18:00:00Z","ended_at":null})

  setup do
    test = self()
    start_supervised!({PublicKey, pem: TestKick.pem(), name: :consumer_test_key})

    start_supervised!(
      {Consumer,
       name: :consumer_test,
       producer: {Broadway.DummyProducer, []},
       public_key: :consumer_test_key,
       dispatch: fn envelopes ->
         send(test, {:dispatched, Enum.map(envelopes, & &1.message_id)})
       end}
    )

    :ok
  end

  defp stored, do: Repo.all(from e in WebhookEvent, order_by: e.message_id)

  test "a good envelope is stored, then acknowledged, then handed on" do
    message = TestKick.message("livestream.status.updated", @status, message_id: "01A")
    ref = Broadway.test_message(:consumer_test, message)

    assert_receive {:ack, ^ref, [_], []}, 2_000
    assert_received {:dispatched, ["01A"]}

    assert [%WebhookEvent{} = e] = stored()
    assert e.body == @status
    assert e.sent_at == "2026-09-24T18:02:11Z"
    assert e.receiver == "test/1"
    # Stream state waits for the channel's process.
    assert e.processed_at == nil
  end

  test "events that need no channel state are marked processed at once" do
    ref = Broadway.test_message(:consumer_test, TestKick.message("moderation.banned", "{}"))
    assert_receive {:ack, ^ref, [_], []}, 2_000
    assert [%{processed_at: %DateTime{}}] = stored()
  end

  test "a repeat is acknowledged but stored and handed on only once" do
    message = TestKick.message("channel.followed", @follow, message_id: "01B")

    ref = Broadway.test_batch(:consumer_test, [message, message])
    assert_receive {:ack, ^ref, [_, _], []}, 2_000
    ref = Broadway.test_message(:consumer_test, message)
    assert_receive {:ack, ^ref, [_], []}, 2_000

    assert [%{message_id: "01B"}] = stored()
    assert_received {:dispatched, ["01B"]}
    assert_received {:dispatched, []}
  end

  test "a bad signature or an undecodable message is dead-lettered, not requeued" do
    for data <- [
          TestKick.message("channel.followed", @follow, key: :other),
          TestKick.message("channel.followed", @follow, signature: "bm90IGEgc2lnbmF0dXJl"),
          "not an envelope",
          TestKick.envelope("channel.followed", @follow)
          |> Map.put("envelope_version", 9)
          |> Jason.encode!()
        ] do
      ref = Broadway.test_message(:consumer_test, data)
      assert_receive {:configure, ^ref, [on_failure: :reject]}, 2_000
      assert_receive {:ack, ^ref, [], [_]}, 2_000
    end

    assert stored() == []
  end

  test "one message that breaks the transaction is dead-lettered alone" do
    good = TestKick.message("channel.followed", @follow, message_id: "01C")
    # Postgres text can't hold a NUL: this one fails inside the transaction.
    bad = TestKick.message("channel.followed", @follow, message_id: "01D\u0000")
    also_good = TestKick.message("channel.followed", @follow, message_id: "01E")

    ref = Broadway.test_batch(:consumer_test, [good, bad, also_good])
    assert_receive {:configure, ^ref, [on_failure: :reject]}, 2_000
    assert_receive {:ack, ^ref, [_, _], [failed]}, 2_000

    assert {:store_failed, _} = failed.status |> elem(1)
    assert Enum.map(stored(), & &1.message_id) == ["01C", "01E"]
  end

  describe "a database that can't take writes for a while" do
    # Fails the first `times` batches with `error`, then stores for real.
    defp start_flaky(name, error, times) do
      {:ok, failures} = Agent.start_link(fn -> times end)
      test = self()

      ingest = fn envelopes ->
        if Agent.get_and_update(failures, &{&1, &1 - 1}) > 0 do
          send(test, :ingest_failed)
          raise error
        else
          KickTracker.Events.ingest(envelopes)
        end
      end

      start_supervised!(
        {Consumer,
         name: name,
         producer: {Broadway.DummyProducer, []},
         public_key: :consumer_test_key,
         dispatch: fn _ -> :ok end,
         ingest: ingest},
        id: name
      )
    end

    defp pg_error(code),
      do: Postgrex.Error.exception(postgres: %{code: code, message: "injected"})

    for {what, code} <- [
          {"an admin shutdown", "57P01"},
          {"a statement timeout", "57014"},
          {"a full disk", "53100"},
          {"a read-only transaction (failover)", "25006"},
          {"a serialization failure", "40001"},
          {"a deadlock", "40P01"},
          {"a lost connection", "08006"}
        ] do
      test "#{what} is waited out, not dead-lettered" do
        name = :"consumer_flaky_#{unquote(code)}"
        start_flaky(name, pg_error(unquote(code)), 2)

        message = TestKick.message("channel.followed", @follow, message_id: "01F")
        ref = Broadway.test_message(name, message)

        assert_receive :ingest_failed, 2_000
        assert_receive :ingest_failed, 2_000
        assert_receive {:ack, ^ref, [_], []}, 5_000
        refute_received {:configure, ^ref, _}
        assert [%{message_id: "01F"}] = stored()
      end
    end

    test "a connection error is waited out too" do
      start_flaky(:consumer_flaky_conn, DBConnection.ConnectionError.exception("gone"), 1)

      ref =
        Broadway.test_message(:consumer_flaky_conn, TestKick.message("channel.followed", @follow))

      assert_receive {:ack, ^ref, [_], []}, 5_000
      assert [_] = stored()
    end

    test "an error in the message itself is still dead-lettered" do
      # 22021: character_not_in_repertoire, a message that can never store.
      start_flaky(:consumer_flaky_bad, pg_error("22021"), 100)

      ref =
        Broadway.test_message(:consumer_flaky_bad, TestKick.message("channel.followed", @follow))

      assert_receive {:configure, ^ref, [on_failure: :reject]}, 2_000
      assert_receive {:ack, ^ref, [], [_]}, 2_000
    end

    test "which errors count as transient" do
      assert Consumer.transient?(DBConnection.ConnectionError.exception("x"))

      for code <-
            ~w(08000 08006 53100 53200 53300 57014 57P01 57P02 57P03 58030 40001 40P01 25006 55P03),
          do: assert(Consumer.transient?(pg_error(code)), code)

      for code <- ~w(22021 23505 23503 42P01 42703 22P02 XX000),
          do: refute(Consumer.transient?(pg_error(code)), code)

      refute Consumer.transient?(%RuntimeError{message: "x"})
      refute Consumer.transient?(:rollback)
    end
  end
end

defmodule KickTracker.Events.ConsumerKeyTest do
  @moduledoc "The consumer when Kick's key changes, or can't be fetched in time."

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  alias KickTracker.Events.Consumer
  alias KickTracker.Kick.PublicKey
  alias KickTracker.TestKick

  @follow ~s({"broadcaster":{"user_id":7},"follower":{"user_id":8}})

  defmodule KeyServer do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, {pem, delay_ms}) do
      Process.sleep(delay_ms)
      body = Jason.encode!(%{"data" => %{"public_key" => pem}, "message" => "OK"})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp key_server(pem, delay_ms) do
    {:ok, server} =
      Bandit.start_link(
        plug: {KeyServer, {pem, delay_ms}},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp start_consumer(name, key_name, opts \\ []) do
    start_supervised!(
      {Consumer,
       [
         name: name,
         producer: {Broadway.DummyProducer, []},
         public_key: key_name,
         dispatch: fn _ -> :ok end
       ] ++ opts},
      id: name
    )
  end

  test "a delivery signed with a rotated key is stored once the new key is fetched" do
    {_private, other_pem} = TestKick.pair(:other)

    start_supervised!(
      {PublicKey, name: :rotating_key, pem: TestKick.pem(), api_url: key_server(other_pem, 0)}
    )

    start_consumer(:consumer_rotating, :rotating_key)
    message = TestKick.message("channel.followed", @follow, key: :other)
    ref = Broadway.test_message(:consumer_rotating, message)

    assert_receive {:ack, ^ref, [_], []}, 5_000
    assert PublicKey.get(:rotating_key) == other_pem
  end

  test "reading the key never waits for a fetch in flight" do
    start_supervised!(
      {PublicKey,
       name: :slow_key, pem: TestKick.pem(), api_url: key_server(TestKick.pem(), 3_000)}
    )

    refresh = Task.async(fn -> PublicKey.refresh(:slow_key) end)
    Process.sleep(100)

    {micros, pem} = :timer.tc(fn -> PublicKey.get(:slow_key) end)
    assert pem == TestKick.pem()
    assert micros < 10_000
    assert Task.await(refresh, 5_000) == {:ok, TestKick.pem()}
  end

  test "a key fetch that doesn't finish in time requeues the message, not dead-letters it" do
    start_supervised!(
      {PublicKey,
       name: :stuck_key, pem: TestKick.pem(), api_url: key_server(TestKick.pem(), 5_000)}
    )

    start_consumer(:consumer_stuck, :stuck_key, key_wait_ms: 200)

    ref =
      Broadway.test_message(
        :consumer_stuck,
        TestKick.message("channel.followed", @follow, key: :other)
      )

    assert_receive {:ack, ^ref, [], [failed]}, 2_000
    assert failed.status == {:failed, :key_unavailable}
    refute_received {:configure, ^ref, _}
  end

  test "once the fetch is done, the same key again means a bad signature" do
    start_supervised!(
      {PublicKey, name: :same_key, pem: TestKick.pem(), api_url: key_server(TestKick.pem(), 0)}
    )

    start_consumer(:consumer_same, :same_key)

    ref =
      Broadway.test_message(
        :consumer_same,
        TestKick.message("channel.followed", @follow, key: :other)
      )

    assert_receive {:configure, ^ref, [on_failure: :reject]}, 2_000
    assert_receive {:ack, ^ref, [], [_]}, 2_000
  end
end

defmodule KickTracker.Events.ConsumerRabbitTest do
  @moduledoc "The consumer against the real broker (the `test` vhost), as the app user."

  use KickTracker.DataCase, async: false
  @moduletag :capture_log

  alias KickTracker.Events.{Consumer, WebhookEvent}
  alias KickTracker.Kick.PublicKey
  alias KickTracker.{TestBroker, TestKick}

  setup do
    TestBroker.purge()
    Application.put_env(:kick_tracker, :amqp_url, TestBroker.app_url())
    on_exit(fn -> Application.delete_env(:kick_tracker, :amqp_url) end)

    start_supervised!({PublicKey, pem: TestKick.pem(), name: :rabbit_test_key})

    start_supervised!(
      {Consumer, name: :rabbit_test, public_key: :rabbit_test_key, dispatch: fn _ -> :ok end}
    )

    :ok
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() || tries == 0, do: fun.(), else: Process.sleep(50) && eventually(fun, tries - 1)
  end

  test "stored and acknowledged; a forged one ends in the dead-letter queue" do
    TestBroker.publish(TestKick.message("channel.followed", "{}", message_id: "01RABBIT"))
    TestBroker.publish(TestKick.message("channel.followed", "{}", key: :other))

    assert eventually(fn -> Repo.aggregate(WebhookEvent, :count) == 1 end)
    assert eventually(fn -> TestBroker.depth("kick_tracker.events.dead") == 1 end)
    assert eventually(fn -> TestBroker.depth("kick_tracker.events") == 0 end)
    assert Repo.get(WebhookEvent, "01RABBIT")
  end
end
