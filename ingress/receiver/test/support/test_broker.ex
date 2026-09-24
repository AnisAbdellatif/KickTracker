defmodule Receiver.TestBroker do
  @moduledoc """
  The development broker's `test` vhost (deploy/rabbitmq), which mirrors
  the real topology, so tests use the real users and exchange without
  touching development data.
  """

  @host "127.0.0.1:55672"

  def receiver_url, do: "amqp://receiver:receiver-dev@#{@host}/test"
  def admin_url, do: "amqp://admin:admin-dev@#{@host}/test"
  # Nothing listens here: a broker that is down.
  def dead_url, do: "amqp://receiver:receiver-dev@127.0.0.1:1/test"

  @doc """
  An exclusive queue bound to `kick.events`, seeing everything published
  from now on, plus the channel to read it with. Closed with the test.
  """
  def observe(exchange \\ "kick.events") do
    {:ok, conn} = AMQP.Connection.open(admin_url())
    {:ok, chan} = AMQP.Channel.open(conn)
    {:ok, %{queue: queue}} = AMQP.Queue.declare(chan, "", exclusive: true)
    :ok = AMQP.Queue.bind(chan, queue, exchange, routing_key: "#")
    ExUnit.Callbacks.on_exit(fn -> safe_close(conn) end)
    {chan, queue}
  end

  @doc "The next message on the observed queue as `{payload, meta}`, or nil after `timeout_ms`."
  def next({chan, queue}, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(chan, queue, deadline)
  end

  @doc "An admin channel on the test vhost, for declaring test-only exchanges."
  def admin_channel do
    {:ok, conn} = AMQP.Connection.open(admin_url())
    {:ok, chan} = AMQP.Channel.open(conn)
    ExUnit.Callbacks.on_exit(fn -> safe_close(conn) end)
    chan
  end

  @doc "Empties the test vhost's real queue, so tests don't pile messages up."
  def purge do
    {:ok, conn} = AMQP.Connection.open(admin_url())
    {:ok, chan} = AMQP.Channel.open(conn)
    {:ok, _} = AMQP.Queue.purge(chan, "kick_tracker.events")
    AMQP.Connection.close(conn)
  end

  @management "http://127.0.0.1:15673/api"

  @doc "The broker's names of the open connections with this client-provided name (management API)."
  def connections(client_name) do
    %{status: 200, body: all} =
      Req.get!(@management <> "/connections",
        auth: {:basic, "admin:admin-dev"},
        params: [columns: "name,user_provided_name"],
        retry: false
      )

    for %{"user_provided_name" => ^client_name, "name" => name} <- all, do: name
  end

  @doc "Has the broker close every connection with this client-provided name."
  def close_connections(client_name) do
    for name <- connections(client_name) do
      Req.delete!(@management <> "/connections/" <> URI.encode(name, &URI.char_unreserved?/1),
        auth: {:basic, "admin:admin-dev"},
        headers: [{"x-reason", "test"}],
        retry: false
      )
    end

    :ok
  end

  defp poll(chan, queue, deadline) do
    case AMQP.Basic.get(chan, queue, no_ack: true) do
      {:ok, payload, meta} ->
        {payload, meta}

      {:empty, _} ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(20)
          poll(chan, queue, deadline)
        end
    end
  end

  defp safe_close(conn) do
    AMQP.Connection.close(conn)
  catch
    _, _ -> :ok
  end
end
