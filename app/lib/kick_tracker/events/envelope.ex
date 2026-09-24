defmodule KickTracker.Events.Envelope do
  @moduledoc """
  Decodes the message the ingress puts on the queue (contracts/envelope.md,
  version 1) and checks its signature again: the app trusts neither the
  queue nor the ingress (project.md §8.1). Pure.

  Unknown fields are ignored, as the contract requires, so an ingress can
  add optional fields without breaking the app. An unknown
  `envelope_version` is an error: a breaking change must come with a
  consumer that reads it.
  """

  alias KickTracker.Kick.Signature

  @enforce_keys [
    :message_id,
    :subscription_id,
    :event_type,
    :event_version,
    :sent_at,
    :occurred_at,
    :signature,
    :body,
    :received_at,
    :receiver
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          message_id: String.t(),
          subscription_id: String.t(),
          event_type: String.t(),
          event_version: String.t(),
          sent_at: String.t(),
          occurred_at: DateTime.t(),
          signature: String.t(),
          body: binary(),
          received_at: DateTime.t(),
          receiver: String.t()
        }

  @strings ~w(message_id subscription_id event_type event_version sent_at signature received_at receiver)

  @doc """
  Decodes a queue message. `body` comes back as the raw bytes Kick sent
  (from `body`, or `body_base64` when it wasn't UTF-8); `sent_at` stays the
  header's own string, since it is part of the signed text, and
  `occurred_at` is it parsed.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    with {:ok, map} <- json(payload),
         :ok <- version(map),
         :ok <- strings(map),
         {:ok, body} <- body(map),
         {:ok, occurred_at} <- timestamp(map["sent_at"], :sent_at),
         {:ok, received_at} <- timestamp(map["received_at"], :received_at) do
      {:ok,
       %__MODULE__{
         message_id: map["message_id"],
         subscription_id: map["subscription_id"],
         event_type: map["event_type"],
         event_version: map["event_version"],
         sent_at: map["sent_at"],
         occurred_at: occurred_at,
         signature: map["signature"],
         body: body,
         received_at: received_at,
         receiver: map["receiver"]
       }}
    end
  end

  @doc "Whether Kick's signature over `message_id.sent_at.body` verifies with this key."
  @spec verified?(t(), String.t() | nil) :: boolean()
  def verified?(_envelope, nil), do: false

  def verified?(%__MODULE__{} = e, pem),
    do: Signature.valid?(pem, e.message_id, e.sent_at, e.body, e.signature)

  @doc "The body parsed as JSON, or an error for a body that isn't."
  @spec payload(t()) :: {:ok, term()} | {:error, :invalid_body}
  def payload(%__MODULE__{body: body}) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_body}
    end
  end

  defp json(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :not_json}
    end
  end

  defp version(%{"envelope_version" => 1}), do: :ok
  defp version(%{"envelope_version" => v}), do: {:error, {:unknown_envelope_version, v}}
  defp version(_), do: {:error, {:missing, "envelope_version"}}

  defp strings(map) do
    case Enum.find(@strings, &(not (is_binary(map[&1]) and map[&1] != ""))) do
      nil -> :ok
      field -> {:error, {:missing, field}}
    end
  end

  defp body(%{"body" => body} = map) when is_binary(body) do
    if Map.has_key?(map, "body_base64"), do: {:error, :both_bodies}, else: {:ok, body}
  end

  defp body(%{"body_base64" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, body} -> {:ok, body}
      :error -> {:error, :invalid_body_base64}
    end
  end

  defp body(_), do: {:error, {:missing, "body"}}

  defp timestamp(value, field) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at |> DateTime.shift_zone!("Etc/UTC") |> usec()}
      {:error, _} -> {:error, {:invalid_timestamp, field}}
    end
  end

  defp usec(%DateTime{microsecond: {us, _}} = at), do: %{at | microsecond: {us, 6}}
end
