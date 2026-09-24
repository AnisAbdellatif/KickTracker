defmodule KickTracker.Admins.Password do
  @moduledoc """
  Password hashing with PBKDF2-HMAC-SHA512 from OTP's `:crypto` (no
  native dependency). Hashes are self-describing
  (`$pbkdf2-sha512$<iterations>$<salt>$<hash>`), so the iteration count can
  be raised later without breaking stored hashes.
  """

  @iterations 210_000
  @salt_bytes 16
  @key_bytes 64

  @doc "Hashes a password with a fresh salt."
  @spec hash(String.t(), pos_integer()) :: String.t()
  def hash(password, iterations \\ iterations()) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    encode(iterations, salt, derive(password, salt, iterations))
  end

  @doc "Whether a password matches a stored hash. Constant time."
  @spec verify(String.t(), String.t() | nil) :: boolean()
  def verify(password, "$pbkdf2-sha512$" <> rest) when is_binary(password) do
    with [iterations, salt, key] <- String.split(rest, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt, padding: false),
         {:ok, key} <- Base.decode64(key, padding: false) do
      :crypto.hash_equals(derive(password, salt, iterations), key)
    else
      _ -> false
    end
  end

  def verify(_password, _hash) do
    no_match()
    false
  end

  @doc "Spends the time a check would, so an unknown email can't be told apart by timing."
  @spec no_match() :: false
  def no_match do
    derive("", <<0::size(@salt_bytes * 8)>>, iterations())
    false
  end

  # Tests lower the cost (config :kick_tracker, :pbkdf2_iterations).
  defp iterations, do: Application.get_env(:kick_tracker, :pbkdf2_iterations, @iterations)

  defp derive(password, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha512, password, salt, iterations, @key_bytes)

  defp encode(iterations, salt, key),
    do:
      "$pbkdf2-sha512$#{iterations}$#{Base.encode64(salt, padding: false)}$#{Base.encode64(key, padding: false)}"
end
