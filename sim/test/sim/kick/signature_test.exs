defmodule Sim.Kick.SignatureTest do
  use ExUnit.Case, async: true

  alias Sim.Kick.Signature

  @id "01JH6X0T5B6Z6W9JQ3E4V8N2QK"
  @ts "2026-09-24T18:02:11Z"
  @body ~s({"broadcaster":{"user_id":1},"is_live":true})

  setup do
    {private, pem} = Sim.TestKeys.pair()
    %{private: private, pem: pem, sig: Signature.sign(private, @id, @ts, @body)}
  end

  test "the signed text is id.timestamp.body" do
    assert Signature.signed_text("a", "b", "c") == "a.b.c"
  end

  test "a signature made like Kick's verifies", %{pem: pem, sig: sig} do
    assert Signature.valid?(pem, @id, @ts, @body, sig)
  end

  test "any change to id, timestamp or body fails", %{pem: pem, sig: sig} do
    refute Signature.valid?(pem, "01JH6X0T5B6Z6W9JQ3E4V8N2QX", @ts, @body, sig)
    refute Signature.valid?(pem, @id, "2026-09-24T18:02:12Z", @body, sig)
    refute Signature.valid?(pem, @id, @ts, @body <> " ", sig)
  end

  test "a reformatted but equivalent body fails: the body must be byte for byte", %{
    pem: pem,
    sig: sig
  } do
    reformatted = @body |> Jason.decode!() |> Jason.encode!(pretty: true)
    refute Signature.valid?(pem, @id, @ts, reformatted, sig)
  end

  test "garbage signature or key is false, not a crash", %{pem: pem, sig: sig} do
    refute Signature.valid?(pem, @id, @ts, @body, "not base64!!")
    refute Signature.valid?(pem, @id, @ts, @body, Base.encode64("short"))
    refute Signature.valid?("not a pem", @id, @ts, @body, sig)
  end
end
