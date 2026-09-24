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
    assert Jason.decode!(conn.resp_body) == %{"ok" => true, "rabbitmq" => false, "spooled" => 1}

    stop_supervised!(Forwarder)
    stop_supervised!(Spool)
    assert Router.call(conn(:get, "/health"), Router.init([])).status == 503
  end

  test "anything else is a 404", ctx do
    start(ctx)
    assert Router.call(conn(:get, "/"), Router.init([])).status == 404
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
