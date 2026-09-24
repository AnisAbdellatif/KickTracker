defmodule KickTracker.Admins.PasswordTest do
  use ExUnit.Case, async: true

  alias KickTracker.Admins.Password

  test "a hash verifies its own password and no other" do
    hash = Password.hash("correct horse battery staple")
    assert hash =~ ~r/^\$pbkdf2-sha512\$\d+\$/
    assert Password.verify("correct horse battery staple", hash)
    refute Password.verify("correct horse battery stapl", hash)
  end

  test "two hashes of one password differ (salted), and both verify" do
    a = Password.hash("same password here")
    b = Password.hash("same password here")
    assert a != b
    assert Password.verify("same password here", a) and Password.verify("same password here", b)
  end

  test "keeps the iteration count in the hash, so it can be raised later" do
    old = Password.hash("an older password", 1_500)
    assert old =~ "$1500$"
    assert Password.verify("an older password", old)
  end

  test "garbage and missing hashes never verify" do
    refute Password.verify("x", nil)
    refute Password.verify("x", "")
    refute Password.verify("x", "$pbkdf2-sha512$abc$def$ghi")
  end
end
