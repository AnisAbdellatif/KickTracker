defmodule Receiver.RouterTest do
  @moduledoc """
  The receiver as Kick sees it: every answer it can give, and where each
  delivery ends up. Against the development broker's `test` vhost.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :tmp_dir

  alias Receiver.{
    Envelope,
    Forwarder,
    Peer,
    PublicKey,
    Publisher,
    Router,
    Signature,
    Spool,
    TestBroker,
    TestKeys
  }

  @body ~s({"broadcaster":{"user_id":7},"follower":{"user_id":8}})

  setup %{tmp_dir: dir} do
    TestBroker.purge()
    {_private, pem} = TestKeys.pair()
    %{spool_path: Path.join(dir, "spool.sqlite3"), pem: pem}
  end

  defp start(ctx, opts \\ []) do
    start_supervised!({PublicKey, pem: Keyword.get(opts, :pem, ctx.pem), api_url: opts[:api_url]})
    start_supervised!({Spool, path: ctx.spool_path})
    url = Keyword.get(opts, :amqp_url, TestBroker.receiver_url())
    start_supervised!({Publisher, url: url, exchange: "kick.events", confirm_timeout_ms: 2_000})
    start_supervised!({Forwarder, interval_ms: 0})
    if url != TestBroker.dead_url(), do: wait_until(fn -> Publisher.connected?() end)
    :ok
  end

  defp deliver(body \\ @body, opts \\ []) do
    {private, _} = TestKeys.pair(Keyword.get(opts, :key, :default))
    headers = TestKeys.headers(private, body, opts)

    conn =
      Enum.reduce(headers, conn(:post, "/", body), fn {k, v}, c -> put_req_header(c, k, v) end)

    conn = Router.call(conn, Router.init([]))
    {conn.status, Jason.decode!(conn.resp_body), Map.new(headers)}
  end

  defp wait_until(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(20) && {:cont, false}
    end)
  end

  test "a signed delivery is published: the app gets an envelope it can verify again", ctx do
    start(ctx)
    observed = TestBroker.observe()

    assert {200, %{"ok" => true}, headers} = deliver()
    assert {payload, meta} = TestBroker.next(observed)

    envelope = Jason.decode!(payload)
    assert meta.message_id == headers["kick-event-message-id"]
    assert meta.routing_key == "channel.followed"
    assert envelope["body"] == @body
    assert envelope["receiver"] == "dev/1"

    assert Signature.valid?(
             ctx.pem,
             envelope["message_id"],
             envelope["sent_at"],
             Envelope.raw_body(envelope),
             envelope["signature"]
           )

    assert Spool.count() == 0
  end

  test "a bad signature is refused with 401 and published nowhere", ctx do
    start(ctx)
    observed = TestBroker.observe()

    assert {401, _, _} = deliver(@body, signature: Base.encode64("forged"))
    assert {401, _, _} = deliver(@body, key: :other)
    assert TestBroker.next(observed, 300) == nil
    assert Spool.count() == 0
  end

  test "a delivery without Kick's headers is a 400 naming what's missing", ctx do
    start(ctx)
    conn = Router.call(conn(:post, "/", @body), Router.init([]))

    assert conn.status == 400
    assert conn.resp_body =~ "kick-event-"
  end

  test "with RabbitMQ down, the delivery is spooled and Kick still gets 200", ctx do
    start(ctx, amqp_url: TestBroker.dead_url())

    assert {200, %{"spooled" => true}, headers} = deliver()
    assert [{_, id, "channel.followed", payload}] = Spool.take(10)
    assert id == headers["kick-event-message-id"]
    assert Jason.decode!(payload)["body"] == @body

    # Kick retrying the same delivery doesn't store it twice.
    {private, _} = TestKeys.pair()
    retry = TestKeys.headers(private, @body, message_id: id)

    conn =
      Enum.reduce(retry, conn(:post, "/", @body), fn {k, v}, c -> put_req_header(c, k, v) end)

    assert Router.call(conn, Router.init([])).status == 200
    assert Spool.count() == 1
  end

  test "once RabbitMQ is back, the forwarder empties the spool, in order", ctx do
    start(ctx, amqp_url: TestBroker.dead_url())
    ids = for _ <- 1..5, do: deliver() |> elem(2) |> Map.fetch!("kick-event-message-id")
    assert Spool.count() == 5

    # RabbitMQ comes back.
    stop_supervised!(Forwarder)
    stop_supervised!(Publisher)
    start_supervised!({Publisher, url: TestBroker.receiver_url(), exchange: "kick.events"})
    start_supervised!({Forwarder, interval_ms: 0})
    wait_until(fn -> Publisher.connected?() end)
    observed = TestBroker.observe()

    assert Forwarder.drain() == 5
    assert Spool.count() == 0

    forwarded = for _ <- 1..5, do: TestBroker.next(observed) |> elem(1) |> Map.fetch!(:message_id)
    assert forwarded == ids
  end

  test "with neither RabbitMQ nor the spool, the answer is 503 so Kick retries", ctx do
    start(ctx, amqp_url: TestBroker.dead_url())
    stop_supervised!(Forwarder)
    stop_supervised!(Spool)

    assert {503, %{"error" => error}, _} = deliver()
    assert error =~ "retry"
  end

  test "until Kick's key is known, deliveries get 503, not a false 401", ctx do
    start(ctx, pem: nil)
    assert {503, _, _} = deliver()
  end

  test "when Kick changes its key, the new one is fetched once and deliveries pass", ctx do
    {_new_private, new_pem} = TestKeys.pair(:rotated)
    {:ok, fetches} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.KeyServer, {new_pem, fetches}},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    start(ctx, api_url: "http://127.0.0.1:#{port}")

    # Signed with the new key, while the receiver still holds the old one.
    assert {200, _, _} = deliver(@body, key: :rotated)
    assert Agent.get(fetches, & &1) == 1

    # A forged delivery right after doesn't make it fetch again.
    assert {401, _, _} = deliver(@body, key: :other)
    assert Agent.get(fetches, & &1) == 1
  end

  test "health says whether it can take deliveries, and how much is waiting", ctx do
    start(ctx, amqp_url: TestBroker.dead_url())
    deliver()

    conn = Router.call(conn(:get, "/health"), Router.init([]))
    assert conn.status == 200

    assert %{
             "ok" => true,
             "rabbitmq" => false,
             "spooled" => 1,
             "spool_bytes" => bytes,
             "spool_over_limit" => false
           } = Jason.decode!(conn.resp_body)

    assert bytes > 0

    stop_supervised!(Forwarder)
    stop_supervised!(Spool)
    assert Router.call(conn(:get, "/health"), Router.init([])).status == 503
  end

  test "a spool past its size limit is reported, and deliveries are still taken", ctx do
    Application.put_env(:receiver, :spool_warn_bytes, 1)
    on_exit(fn -> Application.delete_env(:receiver, :spool_warn_bytes) end)
    start(ctx, amqp_url: TestBroker.dead_url())

    assert {200, %{"spooled" => true}, _} = deliver()
    assert {200, %{"spooled" => true}, _} = deliver()

    conn = Router.call(conn(:get, "/health"), Router.init([]))
    assert conn.status == 200
    assert %{"spool_over_limit" => true, "spooled" => 2} = Jason.decode!(conn.resp_body)
  end

  describe "stepping aside while RabbitMQ is unreachable" do
    setup do
      Application.put_env(:receiver, :broker_grace_s, 0)
      on_exit(fn -> Application.delete_env(:receiver, :broker_grace_s) end)
      :ok
    end

    defp start_peer(rabbitmq?) do
      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__.PeerServer, rabbitmq?},
          port: 0,
          ip: :loopback,
          startup_log: false
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      start_supervised!({Peer, url: "http://127.0.0.1:#{port}/health", poll_ms: 50})
    end

    defp health_status, do: Router.call(conn(:get, "/health"), Router.init([])).status

    test "503 once the grace is over, if the peer can publish", ctx do
      start(ctx, amqp_url: TestBroker.dead_url())
      start_peer(true)
      assert wait_until(fn -> Peer.accepting?() end)

      conn = Router.call(conn(:get, "/health"), Router.init([]))
      assert conn.status == 503
      assert %{"ok" => false, "rabbitmq" => false} = Jason.decode!(conn.resp_body)

      # It still takes a delivery that reaches it anyway.
      assert {200, %{"spooled" => true}, _} = deliver()
    end

    test "stays 200 when the peer can't publish either (the broker is down)", ctx do
      start(ctx, amqp_url: TestBroker.dead_url())
      start_peer(false)
      Process.sleep(200)
      refute Peer.accepting?()
      assert health_status() == 200
    end

    test "stays 200 without a peer, and within the grace", ctx do
      start(ctx, amqp_url: TestBroker.dead_url())
      assert health_status() == 200

      Application.put_env(:receiver, :broker_grace_s, 60)
      start_peer(true)
      assert wait_until(fn -> Peer.accepting?() end)
      assert health_status() == 200
    end

    test "stays 200 while connected, whatever the peer", ctx do
      start(ctx)
      start_peer(true)
      assert wait_until(fn -> Peer.accepting?() end)
      assert health_status() == 200
    end
  end

  test "a broker that stops confirming: deliveries are spooled in bounded time, health answers",
       ctx do
    start_supervised!({PublicKey, pem: ctx.pem})
    start_supervised!({Spool, path: ctx.spool_path})

    # Never confirms: stands in for a broker that has stopped answering.
    never = fn _chan, timeout_ms ->
      Process.sleep(timeout_ms)
      :timeout
    end

    start_supervised!(
      {Publisher,
       url: TestBroker.receiver_url(),
       exchange: "kick.events",
       confirm_timeout_ms: 500,
       confirm: never}
    )

    assert wait_until(fn -> Publisher.connected?() end)

    deliveries =
      for _ <- 1..4, do: Task.async(fn -> :timer.tc(fn -> deliver() end) end)

    Process.sleep(100)
    {micros, health} = :timer.tc(fn -> Router.call(conn(:get, "/health"), Router.init([])) end)
    assert health.status == 200
    assert micros < 200_000

    for task <- deliveries do
      {micros, {status, body, _}} = Task.await(task, 5_000)
      assert status == 200
      assert body["spooled"] == true
      # The confirm timeout plus the second's margin, at most.
      assert micros < 1_700_000
    end

    assert Spool.count() == 4
  end

  test "headers that break the envelope schema are a 400, published nowhere", ctx do
    start(ctx)
    observed = TestBroker.observe()

    assert {400, %{"error" => error}, _} = deliver(@body, event_type: "Channel.Followed!")
    assert error =~ "kick-event-type"
    assert TestBroker.next(observed, 300) == nil
  end

  test "a delivery signed long ago is refused; a recent retry is taken", ctx do
    Application.put_env(:receiver, :max_event_age_s, 86_400)
    on_exit(fn -> Application.delete_env(:receiver, :max_event_age_s) end)
    start(ctx)

    old = DateTime.utc_now() |> DateTime.add(-2 * 86_400) |> DateTime.to_iso8601()
    assert {400, %{"error" => "delivery is too old"}, _} = deliver(@body, timestamp: old)

    recent = DateTime.utc_now() |> DateTime.add(-3_600) |> DateTime.to_iso8601()
    assert {200, _, _} = deliver(@body, timestamp: recent)
  end

  test "a bad signature while Kick's API is slow doesn't hold up good deliveries", ctx do
    {:ok, fetches} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.SlowKeyServer, {ctx.pem, fetches}},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    start(ctx, api_url: "http://127.0.0.1:#{port}")

    forged = Task.async(fn -> :timer.tc(fn -> deliver(@body, key: :other) end) end)
    Process.sleep(100)

    # Meanwhile, a good delivery goes straight through.
    {micros, {status, _, _}} = :timer.tc(fn -> deliver() end)
    assert status == 200
    assert micros < 1_000_000

    # The forged one waits a bounded time for the new key, then is refused.
    {micros, {status, _, _}} = Task.await(forged, 10_000)
    assert status == 401
    assert micros < 4_000_000

    # Another one shares the fetch in flight rather than starting one.
    {micros, {401, _, _}} = :timer.tc(fn -> deliver(@body, key: :other) end)
    assert micros < 4_000_000
    assert Agent.get(fetches, & &1) == 1
  end

  test "anything else is a 404", ctx do
    start(ctx)
    assert Router.call(conn(:get, "/"), Router.init([])).status == 404
  end

  defmodule SlowKeyServer do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, {pem, fetches}) do
      Agent.update(fetches, &(&1 + 1))
      Process.sleep(8_000)
      body = Jason.encode!(%{"data" => %{"public_key" => pem}, "message" => "OK"})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule PeerServer do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, rabbitmq?) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "rabbitmq" => rabbitmq?}))
    end
  end

  defmodule KeyServer do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, {pem, fetches}) do
      Agent.update(fetches, &(&1 + 1))
      body = Jason.encode!(%{"data" => %{"public_key" => pem}, "message" => "OK"})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end
end
