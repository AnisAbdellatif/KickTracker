defmodule Receiver.TestKeys do
  @moduledoc "RSA key pairs for signature tests, and signing like Kick does."

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

  @doc "Kick's six headers for a delivery, signed with the given key."
  @spec headers(:public_key.rsa_private_key(), binary(), keyword()) :: [{String.t(), String.t()}]
  def headers(private, body, opts \\ []) do
    id =
      Keyword.get(
        opts,
        :message_id,
        "01JH6X0T5B6Z6W9JQ3E4V8N2Q#{System.unique_integer([:positive])}"
      )

    ts =
      Keyword.get_lazy(opts, :timestamp, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      end)

    signature =
      :public_key.sign(Receiver.Signature.signed_text(id, ts, body), :sha256, private)
      |> Base.encode64()

    [
      {"kick-event-message-id", id},
      {"kick-event-subscription-id", "01JH6WZQ7F0M1S8Y2D3C4B5A6V"},
      {"kick-event-signature", Keyword.get(opts, :signature, signature)},
      {"kick-event-message-timestamp", ts},
      {"kick-event-type", Keyword.get(opts, :event_type, "channel.followed")},
      {"kick-event-version", "1"}
    ]
  end
end
