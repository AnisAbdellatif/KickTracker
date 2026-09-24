defmodule Receiver.EnvelopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Receiver.{Envelope, Signature, TestKeys}

  @at ~U[2026-09-24 18:02:11.482913Z]
  @body ~s({"broadcaster": {"user_id": 7},  "is_live": true}\n)

  # contracts/envelope.schema.json, the shared contract every ingress must meet.
  @schema "../../contracts/envelope.schema.json"
          |> File.read!()
          |> Jason.decode!()
          |> JSV.build!()

  defp headers(body \\ @body, opts \\ []) do
    {private, _pem} = TestKeys.pair()
    Map.new(TestKeys.headers(private, body, opts))
  end

  defp valid_against_schema?(envelope) do
    # Through JSON, as the app will read it.
    match?({:ok, _}, JSV.validate(envelope |> Jason.encode!() |> Jason.decode!(), @schema))
  end

  test "copies Kick's headers verbatim and adds ours" do
    h =
      headers(@body, message_id: "01JH6X0T5B6Z6W9JQ3E4V8N2QK", timestamp: "2026-09-24T18:02:11Z")

    {:ok, envelope} = Envelope.build(h, @body, @at, "vps-a/1")

    assert envelope["envelope_version"] == 1
    assert envelope["message_id"] == "01JH6X0T5B6Z6W9JQ3E4V8N2QK"
    assert envelope["event_type"] == "channel.followed"
    assert envelope["event_version"] == "1"
    assert envelope["sent_at"] == "2026-09-24T18:02:11Z"
    assert envelope["signature"] == h["kick-event-signature"]
    assert envelope["body"] == @body
    assert envelope["received_at"] == "2026-09-24T18:02:11.482913Z"
    assert envelope["receiver"] == "vps-a/1"
    refute Map.has_key?(envelope, "body_base64")
  end

  test "received_at always has microseconds, as the schema requires" do
    {:ok, envelope} = Envelope.build(headers(), @body, ~U[2026-09-24 18:02:11Z], "r")
    assert envelope["received_at"] == "2026-09-24T18:02:11.000000Z"
  end

  test "a missing header is an error naming it" do
    h = Map.delete(headers(), "kick-event-signature")

    assert Envelope.build(h, @body, @at, "r") ==
             {:error, {:missing_header, "kick-event-signature"}}

    assert {:error, {:missing_header, _}} = Envelope.build(%{}, @body, @at, "r")
  end

  test "a body that isn't UTF-8 travels as base64, and comes back byte for byte" do
    body = <<0xFF, 0xFE, ?{, ?}>>
    {:ok, envelope} = Envelope.build(headers(body), body, @at, "r")

    refute Map.has_key?(envelope, "body")
    assert Envelope.raw_body(envelope) == body
  end

  test "the app can verify the delivery again from the envelope alone" do
    {_private, pem} = TestKeys.pair()
    {:ok, envelope} = Envelope.build(headers(), @body, @at, "r")
    decoded = envelope |> Envelope.encode() |> Jason.decode!()

    assert Signature.valid?(
             pem,
             decoded["message_id"],
             decoded["sent_at"],
             Envelope.raw_body(decoded),
             decoded["signature"]
           )
  end

  test "AMQP properties follow the contract" do
    {:ok, envelope} = Envelope.build(headers(), @body, @at, "r")
    options = Envelope.amqp_options(envelope)

    assert options[:content_type] == "application/json"
    assert options[:message_id] == envelope["message_id"]
    assert options[:type] == "channel.followed"
    assert options[:timestamp] == DateTime.to_unix(@at)
    assert options[:persistent] == true
  end

  describe "the contract (contracts/envelope.schema.json)" do
    test "our envelopes validate, with either kind of body" do
      {:ok, text} = Envelope.build(headers(), @body, @at, "vps-a/1")
      {:ok, binary} = Envelope.build(headers(<<0xFF>>), <<0xFF>>, @at, "vps-a/1")

      assert valid_against_schema?(text)
      assert valid_against_schema?(binary)
    end

    test "the schema really checks: broken envelopes are rejected" do
      {:ok, envelope} = Envelope.build(headers(), @body, @at, "r")

      refute valid_against_schema?(Map.delete(envelope, "message_id"))
      refute valid_against_schema?(Map.put(envelope, "body_base64", "e30="))
      refute valid_against_schema?(Map.put(envelope, "received_at", "2026-09-24T18:02:11Z"))
      refute valid_against_schema?(Map.put(envelope, "envelope_version", 2))
    end

    property "any body, text or not, gives a valid envelope that restores it exactly" do
      check all(body <- one_of([string(:printable), binary()]), max_runs: 200) do
        {:ok, envelope} = Envelope.build(headers(body), body, @at, "r")
        decoded = envelope |> Envelope.encode() |> Jason.decode!()

        assert valid_against_schema?(envelope)
        assert Envelope.raw_body(decoded) == body
      end
    end
  end
end
