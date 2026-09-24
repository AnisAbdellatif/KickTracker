defmodule Sim.Kick.Signature do
  @moduledoc """
  Kick's webhook signature: RSA, SHA-256, PKCS#1 v1.5, over
  `<message_id>.<timestamp>.<raw body>`, base64 in `Kick-Event-Signature`
  (contracts/envelope.md). Pure: no network, no processes.
  """

  @doc "The exact text Kick signs."
  @spec signed_text(String.t(), String.t(), binary()) :: binary()
  def signed_text(message_id, timestamp, body), do: message_id <> "." <> timestamp <> "." <> body

  @doc "True only if the signature is valid base64 and verifies against the PEM public key."
  @spec valid?(String.t(), String.t(), String.t(), binary(), String.t()) :: boolean()
  def valid?(pem, message_id, timestamp, body, signature_b64) do
    with {:ok, signature} <- Base.decode64(signature_b64),
         {:ok, key} <- decode_public_key(pem) do
      :public_key.verify(signed_text(message_id, timestamp, body), :sha256, signature, key)
    else
      _ -> false
    end
  end

  @doc "Signs like Kick does. Used by the simulator (with its own key) and in tests."
  @spec sign(:public_key.rsa_private_key(), String.t(), String.t(), binary()) :: String.t()
  def sign(private_key, message_id, timestamp, body) do
    signed_text(message_id, timestamp, body)
    |> :public_key.sign(:sha256, private_key)
    |> Base.encode64()
  end

  @spec decode_public_key(String.t()) :: {:ok, term()} | :error
  def decode_public_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> :error
    end
  rescue
    _ -> :error
  end
end
