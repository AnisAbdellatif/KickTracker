defmodule KickTracker.Events.EnvelopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KickTracker.Events.Envelope
  alias KickTracker.TestKick

  @body ~s({"broadcaster":{"user_id":7},"follower":{"user_id":8}})

  test "decodes what the ingress sends, keeping the signed parts exact" do
    message = TestKick.message("channel.followed", @body, sent_at: "2026-09-24T18:02:11Z")
    assert {:ok, e} = Envelope.decode(message)

    assert e.body == @body
    assert e.sent_at == "2026-09-24T18:02:11Z"
    assert e.occurred_at == ~U[2026-09-24 18:02:11.000000Z]
    assert e.received_at == ~U[2026-09-24 18:02:11.482913Z]
    assert e.event_type == "channel.followed"
    assert Envelope.verified?(e, TestKick.pem())
  end

  test "an offset timestamp is kept verbatim but stored in UTC" do
    message = TestKick.message("channel.followed", @body, sent_at: "2026-09-24T20:02:11+02:00")
    {:ok, e} = Envelope.decode(message)
    assert e.sent_at == "2026-09-24T20:02:11+02:00"
    assert e.occurred_at == ~U[2026-09-24 18:02:11.000000Z]
    assert Envelope.verified?(e, TestKick.pem())
  end

  test "a body that isn't UTF-8 travels as body_base64 and comes back as bytes" do
    raw = <<0xFF, 0xFE, "{}">>
    env = TestKick.envelope("channel.followed", raw)
    env = env |> Map.delete("body") |> Map.put("body_base64", Base.encode64(raw))
    {:ok, e} = env |> Jason.encode!() |> Envelope.decode()
    assert e.body == raw
    assert Envelope.verified?(e, TestKick.pem())
  end

  test "unknown fields are ignored, as the contract requires" do
    env = TestKick.envelope("channel.followed", @body) |> Map.put("added_later", %{"x" => 1})
    assert {:ok, _} = env |> Jason.encode!() |> Envelope.decode()
  end

  test "what can't be decoded says why" do
    env = TestKick.envelope("channel.followed", @body)
    decode = fn map -> map |> Jason.encode!() |> Envelope.decode() end

    assert Envelope.decode("not json") == {:error, :not_json}
    assert decode.(%{env | "envelope_version" => 2}) == {:error, {:unknown_envelope_version, 2}}
    assert decode.(Map.delete(env, "message_id")) == {:error, {:missing, "message_id"}}
    assert decode.(%{env | "sent_at" => ""}) == {:error, {:missing, "sent_at"}}
    assert decode.(Map.delete(env, "body")) == {:error, {:missing, "body"}}
    assert decode.(Map.put(env, "body_base64", "e30=")) == {:error, :both_bodies}
    assert decode.(%{env | "sent_at" => "yesterday"}) == {:error, {:invalid_timestamp, :sent_at}}
  end

  test "a tampered body, a wrong key or no key never verifies" do
    {:ok, e} = TestKick.message("channel.followed", @body) |> Envelope.decode()

    refute Envelope.verified?(%{e | body: @body <> " "}, TestKick.pem())
    refute Envelope.verified?(%{e | sent_at: "2026-09-24T18:02:12Z"}, TestKick.pem())
    refute Envelope.verified?(e, TestKick.pem(:other))
    refute Envelope.verified?(e, nil)
  end

  property "any body survives the trip and still verifies" do
    check all(body <- one_of([string(:printable), binary()]), max_runs: 50) do
      env = TestKick.envelope("channel.followed", body)

      env =
        if String.valid?(body),
          do: env,
          else: env |> Map.delete("body") |> Map.put("body_base64", Base.encode64(body))

      {:ok, e} = env |> Jason.encode!() |> Envelope.decode()
      assert e.body == body
      assert Envelope.verified?(e, TestKick.pem())
    end
  end
end
