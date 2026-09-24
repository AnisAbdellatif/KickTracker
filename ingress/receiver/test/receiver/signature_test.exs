defmodule Receiver.SignatureTest do
  use ExUnit.Case, async: true

  alias Receiver.{Signature, TestKeys}

  test "verifies what was signed, and nothing else" do
    {private, pem} = TestKeys.pair()
    body = ~s({"a": 1})

    sig =
      :public_key.sign(Signature.signed_text("m1", "t1", body), :sha256, private)
      |> Base.encode64()

    assert Signature.valid?(pem, "m1", "t1", body, sig)
    refute Signature.valid?(pem, "m2", "t1", body, sig)
    refute Signature.valid?(pem, "m1", "t2", body, sig)
    refute Signature.valid?(pem, "m1", "t1", body <> " ", sig)
    refute Signature.valid?(pem, "m1", "t1", body, "not base64!")
    refute Signature.valid?("not a key", "m1", "t1", body, sig)

    {_other, other_pem} = TestKeys.pair(:other)
    refute Signature.valid?(other_pem, "m1", "t1", body, sig)
  end
end
