defmodule Receiver.Envelope do
  @moduledoc """
  Turns one webhook delivery into the envelope defined in
  `contracts/envelope.md` (version 1). Pure.

  `message_id`, `sent_at` and the body are copied exactly: together they
  are the text Kick signed, so the app can verify the delivery again and
  trust neither the queue nor the receiver.

  The headers are checked against the schema's limits
  (`contracts/envelope.schema.json`) before anything else, so nothing that
  breaks the contract is published: `event_type`, `subscription_id` and
  `event_version` are **not** signed, and the event type becomes the
  routing key.
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

  # The schema's rules for each header field (contracts/envelope.schema.json).
  @rules %{
    "message_id" => {:length, 128},
    "subscription_id" => {:length, 128},
    "event_type" => {:pattern, ~r/\A[a-z0-9_]+(\.[a-z0-9_]+)+\z/},
    "event_version" => {:length, 16},
    "sent_at" => {:length, 64},
    "signature" => {:pattern, ~r/\A[A-Za-z0-9+\/]+={0,2}\z/}
  }

  @doc """
  Builds the envelope from the request's headers (lowercased names), its
  raw body, when it was received, and which receiver took it.
  """
  @spec build(%{String.t() => String.t()}, binary(), DateTime.t(), String.t()) ::
          {:ok, map()}
          | {:error, {:missing_header, String.t()} | {:invalid_header, String.t()}}
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

  @doc """
  Whether `sent_at` is older than `max_age_s` at `now`. A timestamp that
  can't be parsed is not judged here (the app dead-letters it, where it
  can still be looked at); only a readable, too old one is.
  """
  @spec too_old?(String.t(), DateTime.t(), pos_integer() | nil) :: boolean()
  def too_old?(_sent_at, _now, nil), do: false

  def too_old?(sent_at, %DateTime{} = now, max_age_s) do
    case DateTime.from_iso8601(sent_at) do
      {:ok, at, _offset} -> DateTime.diff(now, at, :second) > max_age_s
      {:error, _} -> false
    end
  end

  defp from_headers(headers) do
    Enum.reduce_while(@headers, {:ok, %{}}, fn {field, header}, {:ok, acc} ->
      case Map.get(headers, header) do
        value when is_binary(value) and value != "" ->
          if valid?(field, value),
            do: {:cont, {:ok, Map.put(acc, field, value)}},
            else: {:halt, {:error, {:invalid_header, header}}}

        _ ->
          {:halt, {:error, {:missing_header, header}}}
      end
    end)
  end

  defp valid?(field, value) do
    case @rules[field] do
      {:length, max} -> String.valid?(value) and length(String.codepoints(value)) <= max
      {:pattern, regex} -> Regex.match?(regex, value)
    end
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
