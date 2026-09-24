defmodule Receiver.Router do
  @moduledoc """
  What Kick calls. For each delivery (project.md §8.4):

    1. read the raw body and the `Kick-Event-*` headers;
    2. verify the signature with Kick's public key; if it fails, fetch the
       key again once (it may have changed) and retry, then refuse with 401;
    3. build the envelope (contracts/envelope.md);
    4. publish it and wait for RabbitMQ's confirm; if that fails for any
       reason, write it to the local spool instead;
    5. answer 200.

  200 means the delivery is safe: confirmed by RabbitMQ or on this
  machine's disk. When neither is possible the answer is 503, so Kick
  retries rather than believing it was received.

  `GET /health` is for the load balancer: 200 while the receiver can accept
  deliveries (its spool works), with whether RabbitMQ is connected and how
  much is spooled.
  """

  use Plug.Router
  require Logger

  alias Receiver.{Envelope, PublicKey, Publisher, Signature, Spool}

  @max_body 1_000_000

  plug(:match)
  plug(:dispatch)

  get "/health" do
    health(conn)
  end

  post _ do
    with {:ok, body, conn} <- read_full_body(conn),
         {:ok, envelope} <- build(conn, body),
         :ok <- verify(envelope, body) do
      envelope |> deliver() |> reply(conn)
    else
      {:error, :too_large} -> json(conn, 413, %{"error" => "body too large"})
      {:error, {:missing_header, header}} -> json(conn, 400, %{"error" => "missing #{header}"})
      {:error, :no_key} -> json(conn, 503, %{"error" => "Kick's public key isn't available yet"})
      {:error, :bad_signature} -> json(conn, 401, %{"error" => "signature does not verify"})
      {:error, :read_failed} -> json(conn, 400, %{"error" => "could not read the body"})
    end
  end

  match _ do
    json(conn, 404, %{"error" => "not found"})
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
        cond do
          valid?(pem, envelope, body) -> :ok
          # Kick may have changed its key: fetch it again (at most once a
          # minute) and give the delivery one more chance.
          valid?(PublicKey.refresh(), envelope, body) -> :ok
          true -> {:error, :bad_signature}
        end
    end
  end

  defp valid?(nil, _envelope, _body), do: false

  defp valid?(pem, envelope, body),
    do:
      Signature.valid?(
        pem,
        envelope["message_id"],
        envelope["sent_at"],
        body,
        envelope["signature"]
      )

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
    body = %{"ok" => true, "rabbitmq" => Publisher.connected?(), "spooled" => Spool.count()}
    json(conn, 200, body)
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
