defmodule Sim.Keys do
  @moduledoc """
  The simulator's own RSA key pair. It signs webhooks with the private key
  and serves the public one from `/public/v1/public-key`, exactly as Kick
  does, so the code under test verifies signatures for real instead of
  being told to skip the check.
  """

  @type t :: %{private: :public_key.rsa_private_key(), pem: String.t()}

  @doc "Generates a key pair and its public PEM."
  @spec generate() :: t()
  def generate do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private
    public = {:RSAPublicKey, modulus, exponent}
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])
    %{private: private, pem: pem}
  end
end
