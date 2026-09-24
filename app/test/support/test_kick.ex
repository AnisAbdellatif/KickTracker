defmodule KickTracker.TestKick do
  @moduledoc """
  Kick as tests need it: an RSA key pair to sign with, and envelopes the
  way the ingress builds them (contracts/envelope.md), signed like Kick
  signs its deliveries.
  """

  alias KickTracker.Kick.Signature

  @doc "A key pair, generated once per name and reused: `{private, public_pem}`."
  @spec pair(atom()) :: {:public_key.rsa_private_key(), String.t()}
  def pair(name \\ :default) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil ->
        private = :public_key.generate_key({:rsa, 2048, 65_537})
        {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private

        pem =
          :public_key.pem_encode([
            :public_key.pem_entry_encode(
              :SubjectPublicKeyInfo,
              {:RSAPublicKey, modulus, exponent}
            )
          ])

        :persistent_term.put({__MODULE__, name}, {private, pem})
        {private, pem}

      pair ->
        pair
    end
  end

  @doc "The public half of `pair/1`."
  @spec pem(atom()) :: String.t()
  def pem(name \\ :default), do: name |> pair() |> elem(1)

  @doc """
  An envelope as a map, for an event with this body (a map is JSON-encoded,
  a binary is used as is). Options: `:message_id`, `:sent_at`, `:key` (the
  signing key's name), `:signature`, `:event_version`.
  """
  @spec envelope(String.t(), map() | binary(), keyword()) :: map()
  def envelope(event_type, body, opts \\ []) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    message_id = Keyword.get_lazy(opts, :message_id, &message_id/0)
    sent_at = Keyword.get(opts, :sent_at, "2026-09-24T18:02:11Z")
    {private, _} = pair(Keyword.get(opts, :key, :default))

    signature =
      Keyword.get_lazy(opts, :signature, fn ->
        Signature.signed_text(message_id, sent_at, body)
        |> :public_key.sign(:sha256, private)
        |> Base.encode64()
      end)

    %{
      "envelope_version" => 1,
      "message_id" => message_id,
      "subscription_id" => "01JH6WZQ7F0M1S8Y2D3C4B5A6V",
      "event_type" => event_type,
      "event_version" => Keyword.get(opts, :event_version, "1"),
      "sent_at" => sent_at,
      "signature" => signature,
      "body" => body,
      "received_at" => "2026-09-24T18:02:11.482913Z",
      "receiver" => "test/1"
    }
  end

  @doc "`envelope/3`, encoded as the queue message it travels as."
  @spec message(String.t(), map() | binary(), keyword()) :: binary()
  def message(event_type, body, opts \\ []),
    do: event_type |> envelope(body, opts) |> Jason.encode!()

  @doc "A fresh ULID-shaped message id."
  @spec message_id() :: String.t()
  def message_id do
    n = System.unique_integer([:positive, :monotonic])
    "01TEST" <> String.pad_leading(Integer.to_string(n, 32) |> String.upcase(), 20, "0")
  end

  @doc "A Kick user as webhook bodies carry them."
  @spec user(integer(), String.t()) :: map()
  def user(user_id, username \\ nil) do
    %{
      "user_id" => user_id,
      "username" => username || "user#{user_id}",
      "channel_slug" => username || "user#{user_id}",
      "is_verified" => false,
      "is_anonymous" => false,
      "identity" => nil,
      "profile_picture" => nil
    }
  end
end
