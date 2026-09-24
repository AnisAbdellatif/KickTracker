defmodule KickTracker.Admins.TOTPTest do
  use ExUnit.Case, async: true

  alias KickTracker.Admins.TOTP

  doctest TOTP

  # RFC 6238 appendix B (SHA-1), last six digits.
  @secret "12345678901234567890"

  test "matches the RFC 6238 test vectors" do
    for {unix, code} <- [
          {59, "287082"},
          {1_111_111_109, "081804"},
          {1_234_567_890, "005924"},
          {2_000_000_000, "279037"}
        ] do
      assert TOTP.code(@secret, TOTP.step_at(DateTime.from_unix!(unix))) == code
    end
  end

  test "accepts the current code and one step either side, nothing further" do
    at = DateTime.from_unix!(1_234_567_890)
    step = TOTP.step_at(at)

    assert TOTP.verify(@secret, TOTP.code(@secret, step), at) == {:ok, step}
    assert TOTP.verify(@secret, TOTP.code(@secret, step - 1), at) == {:ok, step - 1}
    assert TOTP.verify(@secret, TOTP.code(@secret, step + 1), at) == {:ok, step + 1}
    assert TOTP.verify(@secret, TOTP.code(@secret, step - 2), at) == :error
    assert TOTP.verify(@secret, "12345", at) == :error
    assert TOTP.verify(@secret, "", at) == :error
  end

  test "tolerates spaces in a typed code" do
    at = DateTime.from_unix!(1_234_567_890)
    <<a::binary-3, b::binary-3>> = TOTP.code(@secret, TOTP.step_at(at))
    assert {:ok, _} = TOTP.verify(@secret, a <> " " <> b, at)
  end

  test "refuses a code for a step already used" do
    at = DateTime.from_unix!(1_234_567_890)
    step = TOTP.step_at(at)
    code = TOTP.code(@secret, step)

    assert TOTP.verify(@secret, code, at, step) == :error
    assert TOTP.verify(@secret, code, at, step - 1) == {:ok, step}
  end

  test "the provisioning URI carries the secret in base32" do
    uri = TOTP.uri(@secret, "someone@example.com", "Stream Tracker")
    assert uri =~ "otpauth://totp/Stream%20Tracker%3Asomeone%40example.com?"
    assert uri =~ "secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
  end
end
