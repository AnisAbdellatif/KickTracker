defmodule Sim.Recorder.WebhookCapture do
  @moduledoc """
  A Plug that records every webhook delivery exactly as received: all
  headers and the raw body, byte for byte, plus whether its signature
  verified and what we answered. Answers per `Sim.Recorder.WebhookPolicy`.

  These raw recordings keep Kick's real signatures, which is what makes them
  usable for signature tests; they stay in `sim/recordings/` (git-ignored).
  """

  @behaviour Plug

  import Plug.Conn

  alias Sim.Kick.Signature
  alias Sim.Recorder.{Store, WebhookPolicy}

  @max_body 1_000_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    received_at = DateTime.utc_now() |> DateTime.to_iso8601()

    case read_full_body(conn, []) do
      {:ok, body, conn} ->
        header = &(conn |> get_req_header(&1) |> List.first())

        message_id =
          header.("kick-event-message-id") || "missing-#{System.unique_integer([:positive])}"

        status = WebhookPolicy.decide(opts[:policy], message_id)

        signature_valid =
          with pem when is_binary(pem) <- opts[:public_key],
               id when is_binary(id) <- header.("kick-event-message-id"),
               ts when is_binary(ts) <- header.("kick-event-message-timestamp"),
               sig when is_binary(sig) <- header.("kick-event-signature") do
            Signature.valid?(pem, id, ts, body, sig)
          else
            _ -> nil
          end

        Store.write(opts[:run], "webhook", header.("kick-event-type") || "unknown", %{
          "kind" => "webhook",
          "recorded_at" => received_at,
          "request" => %{
            "method" => conn.method,
            "path" => conn.request_path,
            "headers" => Enum.map(conn.req_headers, fn {k, v} -> [k, v] end),
            "body" => body
          },
          "signature_valid" => signature_valid,
          "answered" => status
        })

        Mix.shell().info(
          "#{received_at} #{header.("kick-event-type")} #{message_id} -> #{status}" <>
            if(signature_valid == false, do: " (SIGNATURE INVALID)", else: "")
        )

        send_resp(conn, status, "")

      {:error, :too_large} ->
        send_resp(conn, 413, "")

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")

  defp read_full_body(conn, acc) do
    case read_body(conn, length: @max_body) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary([acc, chunk]), conn}

      {:more, chunk, conn} ->
        if IO.iodata_length([acc, chunk]) > @max_body,
          do: {:error, :too_large},
          else: read_full_body(conn, [acc, chunk])

      {:error, reason} ->
        {:error, reason}
    end
  end
end
