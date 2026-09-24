defmodule Receiver.Envelope do
  @moduledoc """
  Turns one webhook delivery into the envelope defined in
  `contracts/envelope.md` (version 1). Pure.

  `message_id`, `sent_at` and the body are copied exactly: together they
  are the text Kick signed, so the app can verify the delivery again and
  trust neither the queue nor the receiver.
  """

  @version 1

  @headers %{
    "message_id" => "kick-event-message-id",
    "subscription_id" => "kick-event-subscription-id",
    "event_type" => "kick-event-type",
    "event_version" => "kick-event-version",
    "sent_at" => "kick-event-message-timestamp",
    "signature" => "kick-event-signature"
  }

  @doc """
  Builds the envelope from the request's headers (lowercased names), its
  raw body, when it was received, and which receiver took it.
  """
  @spec build(%{String.t() => String.t()}, binary(), DateTime.t(), String.t()) ::
          {:ok, map()} | {:error, {:missing_header, String.t()}}
  def build(headers, body, %DateTime{} = received_at, receiver) do
    with {:ok, fields} <- from_headers(headers) do
      envelope =
        fields
        |> Map.put("envelope_version", @version)
        |> Map.put("received_at", timestamp(received_at))
        |> Map.put("receiver", receiver)
        |> put_body(body)

      {:ok, envelope}
    end
  end

  @doc "The raw body again, from either `body` or `body_base64`."
  @spec raw_body(map()) :: binary()
  def raw_body(%{"body" => body}), do: body
  def raw_body(%{"body_base64" => encoded}), do: Base.decode64!(encoded)

  @doc "The message as published: JSON."
  @spec encode(map()) :: binary()
  def encode(envelope), do: Jason.encode!(envelope)

  @doc "AMQP properties for the message (contracts/envelope.md, Transport)."
  @spec amqp_options(map()) :: keyword()
  def amqp_options(envelope) do
    {:ok, received_at, 0} = DateTime.from_iso8601(envelope["received_at"])

    [
      content_type: "application/json",
      message_id: envelope["message_id"],
      type: envelope["event_type"],
      timestamp: DateTime.to_unix(received_at),
      persistent: true
    ]
  end

  defp from_headers(headers) do
    Enum.reduce_while(@headers, {:ok, %{}}, fn {field, header}, {:ok, acc} ->
      case Map.get(headers, header) do
        value when is_binary(value) and value != "" -> {:cont, {:ok, Map.put(acc, field, value)}}
        _ -> {:halt, {:error, {:missing_header, header}}}
      end
    end)
  end

  # The body travels as a string when it is UTF-8 (Kick's always is), and
  # base64 otherwise, so no byte can be lost either way.
  defp put_body(envelope, body) do
    if String.valid?(body),
      do: Map.put(envelope, "body", body),
      else: Map.put(envelope, "body_base64", Base.encode64(body))
  end

  # RFC 3339, UTC, always microseconds, as the schema requires.
  defp timestamp(at) do
    {us, _} = at.microsecond

    at
    |> DateTime.shift_zone!("Etc/UTC")
    |> Map.put(:microsecond, {us, 6})
    |> DateTime.to_iso8601()
  end
end
