defmodule KickTracker.Admins.TOTP do
  @moduledoc """
  Time-based one-time passwords (RFC 6238, HMAC-SHA1, 6 digits, 30s
  steps), the admin's second factor (project.md §13.8). Pure.

  `verify/4` returns the time step a code matched, so the caller can store
  it and refuse the same code twice.
  """

  import Bitwise, only: [&&&: 2]

  @step 30
  @digits 6

  @doc "A new random secret (20 bytes, as RFC 4226 recommends)."
  @spec new_secret() :: binary()
  def new_secret, do: :crypto.strong_rand_bytes(20)

  @doc "The secret as authenticator apps expect it (base32, no padding)."
  @spec encode_secret(binary()) :: String.t()
  def encode_secret(secret), do: Base.encode32(secret, padding: false)

  @doc "An `otpauth://` URI for authenticator apps."
  @spec uri(binary(), String.t(), String.t()) :: String.t()
  def uri(secret, account, issuer) do
    label = URI.encode(issuer <> ":" <> account, &URI.char_unreserved?/1)

    query =
      URI.encode_query(%{
        "secret" => encode_secret(secret),
        "issuer" => issuer,
        "algorithm" => "SHA1",
        "digits" => @digits,
        "period" => @step
      })

    "otpauth://totp/#{label}?#{query}"
  end

  @doc "The time step a moment falls in."
  @spec step_at(DateTime.t()) :: non_neg_integer()
  def step_at(%DateTime{} = at), do: div(DateTime.to_unix(at), @step)

  @doc """
  The code for a time step.

      iex> KickTracker.Admins.TOTP.code("12345678901234567890", 1)
      "287082"
  """
  @spec code(binary(), non_neg_integer()) :: String.t()
  def code(secret, step) do
    mac = :crypto.mac(:hmac, :sha, secret, <<step::unsigned-big-64>>)
    offset = :binary.last(mac) &&& 0x0F
    <<_::binary-size(^offset), value::unsigned-big-32, _::binary>> = mac

    (value &&& 0x7FFFFFFF)
    |> rem(Integer.pow(10, @digits))
    |> Integer.to_string()
    |> String.pad_leading(@digits, "0")
  end

  @doc """
  Checks a code at `at`, allowing one step of clock drift either way. A
  code for a step at or before `last_step` (the last one accepted) is
  refused, so an observed code can't be replayed.
  """
  @spec verify(binary(), String.t(), DateTime.t(), non_neg_integer() | nil) ::
          {:ok, non_neg_integer()} | :error
  def verify(secret, code, at, last_step \\ nil) when is_binary(code) do
    code = String.replace(code, ~r/\s/, "")
    now = step_at(at)

    Enum.find_value([now - 1, now, now + 1], :error, fn step ->
      if (last_step == nil or step > last_step) and
           :crypto.hash_equals(code(secret, step), pad(code)),
         do: {:ok, step}
    end)
  end

  # hash_equals needs equal sizes; a wrong-length code simply won't match.
  defp pad(code) when byte_size(code) == @digits, do: code
  defp pad(_code), do: String.duplicate("x", @digits)
end
