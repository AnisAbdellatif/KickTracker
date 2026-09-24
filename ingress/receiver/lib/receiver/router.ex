defmodule Receiver.Router do
  @moduledoc """
  What Kick calls. For each delivery (project.md §8.4):

    1. read the raw body and the `Kick-Event-*` headers, and check them
       against the envelope schema's limits (400 if they break it);
    2. verify the signature with Kick's public key; if it fails, fetch the
       key again (at most once a minute, waiting at most a few seconds) and,
       if a different key comes back, retry with it; then refuse with 401;
    3. refuse (400) a delivery whose signed `sent_at` is older than
       `MAX_EVENT_AGE_S`, so an old captured delivery can't be replayed;
    4. build the envelope (contracts/envelope.md);
    5. publish it and wait for RabbitMQ's confirm, for a bounded time; if
       that fails for any reason, write it to the local spool instead;
    6. answer 200.

  200 means the delivery is safe: confirmed by RabbitMQ or on this
  machine's disk. When neither is possible, or anything unexpected goes
  wrong, the answer is 503, so Kick retries rather than believing it was
  received.

  `GET /health` is for the load balancer, and never waits on RabbitMQ or
  the publisher. 200 while the receiver can accept deliveries (its spool
  works), with whether RabbitMQ is connected and how much is spooled. 503
  when the spool doesn't answer, or when RabbitMQ has been unreachable for
  longer than `HEALTH_BROKER_GRACE_S` **and** the peer receiver can
  publish (`Receiver.Peer`): the load balancer then moves deliveries to the
  peer instead of piling them up in this receiver's spool.
  """

  use Plug.Router
  require Logger

  alias Receiver.{Envelope, Peer, PublicKey, Publisher, Signature, Spool}

  @max_body 1_000_000

  plug(:match)
  plug(:dispatch)

  get "/health" do
    health(conn)
  end

  post _ do
    receive_delivery(conn)
  end

  match _ do
    json(conn, 404, %{"error" => "not found"})
  end

  defp receive_delivery(conn) do
    with {:ok, body, conn} <- read_full_body(conn),
         {:ok, envelope} <- build(conn, body),
         :ok <- verify(envelope, body),
         :ok <- fresh(envelope) do
      envelope |> deliver() |> reply(conn)
    else
      {:error, :too_large} -> json(conn, 413, %{"error" => "body too large"})
      {:error, {:missing_header, header}} -> json(conn, 400, %{"error" => "missing #{header}"})
      {:error, {:invalid_header, header}} -> json(conn, 400, %{"error" => "invalid #{header}"})
      {:error, :no_key} -> json(conn, 503, %{"error" => "Kick's public key isn't available yet"})
      {:error, :bad_signature} -> json(conn, 401, %{"error" => "signature does not verify"})
      {:error, :too_old} -> json(conn, 400, %{"error" => "delivery is too old"})
      {:error, :read_failed} -> json(conn, 400, %{"error" => "could not read the body"})
    end
  rescue
    # Never a 500 that Kick may take as final: whatever went wrong, it
    # should retry.
    error ->
      Logger.error("delivery failed: " <> Exception.format(:error, error, __STACKTRACE__))
      json(conn, 503, %{"error" => "could not take the delivery; please retry"})
  end

  defp build(conn, body) do
    headers = Map.new(conn.req_headers)

    Envelope.build(
      headers,
      body,
      DateTime.utc_now(),
      Application.fetch_env!(:receiver, :receiver_id)
    )
  end

  defp verify(envelope, body) do
    case PublicKey.get() do
      nil ->
        {:error, :no_key}

      pem ->
        if valid?(pem, envelope, body) or valid_with_new_key?(pem, envelope, body),
          do: :ok,
          else: {:error, :bad_signature}
    end
  end

  # Kick may have changed its key: fetch it again (at most once a minute,
  # waiting a few seconds at most) and give the delivery one more chance,
  # only if the key really is different.
  defp valid_with_new_key?(old, envelope, body) do
    case PublicKey.refresh() do
      new when new in [nil, old] -> false
      new -> valid?(new, envelope, body)
    end
  end

  defp valid?(pem, envelope, body),
    do:
      Signature.valid?(
        pem,
        envelope["message_id"],
        envelope["sent_at"],
        body,
        envelope["signature"]
      )

  defp fresh(envelope) do
    max_age = Application.get_env(:receiver, :max_event_age_s)

    if Envelope.too_old?(envelope["sent_at"], DateTime.utc_now(), max_age) do
      Logger.warning("refusing #{envelope["message_id"]}: sent at #{envelope["sent_at"]}")
      {:error, :too_old}
    else
      :ok
    end
  end

  # Confirmed by RabbitMQ, or failing that, on this machine's disk.
  defp deliver(envelope) do
    payload = Envelope.encode(envelope)
    key = envelope["event_type"]

    case Publisher.publish(key, payload, Envelope.amqp_options(envelope)) do
      :ok ->
        :published

      {:error, reason} ->
        Logger.warning("spooling #{envelope["message_id"]}: #{inspect(reason)}")

        case Spool.put(envelope["message_id"], key, payload) do
          :ok -> :spooled
          {:error, spool_error} -> {:lost, reason, spool_error}
        end
    end
  end

  defp reply(:published, conn), do: json(conn, 200, %{"ok" => true})
  defp reply(:spooled, conn), do: json(conn, 200, %{"ok" => true, "spooled" => true})

  defp reply({:lost, reason, spool_error}, conn) do
    Logger.error("could not publish or spool: #{inspect(reason)} / #{inspect(spool_error)}")
    json(conn, 503, %{"error" => "could not store the delivery; please retry"})
  end

  defp health(conn) do
    # Well inside the load balancer's 2s health timeout.
    spool = Spool.stats(Spool, 1_500)
    publisher = Publisher.status()
    warn_bytes = Application.get_env(:receiver, :spool_warn_bytes)
    grace_ms = Application.get_env(:receiver, :broker_grace_s, 30) * 1_000

    step_aside? =
      publisher.disconnected_for_ms != nil and publisher.disconnected_for_ms > grace_ms and
        Peer.accepting?()

    body = %{
      "ok" => not step_aside?,
      "rabbitmq" => publisher.connected,
      "spooled" => spool.count,
      "spool_bytes" => spool.bytes,
      # Nothing is ever refused for this: it is a warning to act on.
      "spool_over_limit" => warn_bytes != nil and spool.bytes > warn_bytes
    }

    if step_aside?,
      do: json(conn, 503, Map.put(body, "error", "RabbitMQ unreachable; the peer can publish")),
      else: json(conn, 200, body)
  catch
    :exit, _ -> json(conn, 503, %{"ok" => false, "error" => "spool unavailable"})
  end

  defp read_full_body(conn, acc \\ []) do
    case read_body(conn, length: @max_body) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary([acc, chunk]), conn}

      {:more, chunk, conn} ->
        if IO.iodata_length([acc, chunk]) > @max_body,
          do: {:error, :too_large},
          else: read_full_body(conn, [acc, chunk])

      {:error, _} ->
        {:error, :read_failed}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
