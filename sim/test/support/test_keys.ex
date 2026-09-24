defmodule Sim.TestKeys do
  @moduledoc "An RSA key pair for signature tests, generated once per test run."

  @spec pair() :: {:public_key.rsa_private_key(), String.t()}
  def pair do
    case :persistent_term.get({__MODULE__, :pair}, nil) do
      nil ->
        private = :public_key.generate_key({:rsa, 2048, 65_537})
        {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private
        public = {:RSAPublicKey, modulus, exponent}

        pem =
          :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])

        pair = {private, pem}
        :persistent_term.put({__MODULE__, :pair}, pair)
        pair

      pair ->
        pair
    end
  end
end
