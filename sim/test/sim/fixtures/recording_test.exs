defmodule Sim.Fixtures.RecordingTest do
  use ExUnit.Case, async: true

  alias Sim.Fixtures.{Anonymizer, Recording}

  test "http: drops request headers, keeps allowed response headers, pseudonymizes slugs and ids" do
    rec = %{
      "kind" => "http",
      "request" => %{
        "method" => "GET",
        "url" => "https://kick.com/api/v2/channels/somestreamer",
        "params" => %{"slug" => "SomeStreamer", "broadcaster_user_id" => 5},
        "headers" => [["user-agent", "kick-tracker-recorder/0.1 (+me@example.com)"]],
        "json" => nil
      },
      "response" => %{
        "status" => 200,
        "headers" => [
          ["content-type", "application/json"],
          ["set-cookie", "__cf_bm=abc"],
          ["x-ratelimit-remaining", "99"],
          ["cf-ray", "123"]
        ],
        "body" => ~s({"id":1,"slug":"somestreamer","followers_count":1234})
      }
    }

    {out, _} = Recording.anonymize(rec, Anonymizer.new())

    assert out["request"]["url"] == "https://kick.com/api/v2/channels/user0001"

    assert out["request"]["params"] == %{
             "slug" => "user0001",
             "broadcaster_user_id" => 900_000_001
           }

    refute Map.has_key?(out["request"], "headers")

    assert Enum.map(out["response"]["headers"], &hd/1) == [
             "content-type",
             "x-ratelimit-remaining"
           ]

    body = Jason.decode!(out["response"]["body"])
    assert body["slug"] == "user0001"
    assert body["followers_count"] == 1_234
    refute inspect(out) =~ ~r/somestreamer|me@example/i
  end

  test "http: numeric ids after /channels/ and in id params are mapped like other ids" do
    rec = %{
      "kind" => "http",
      "request" => %{
        "method" => "GET",
        "url" => "https://api.kick.com/private/v0/channels/7654321/viewer-count",
        "params" => %{"ids[]" => 555}
      },
      "response" => %{"status" => 200, "headers" => [], "body" => ~s({"viewer_count":10})}
    }

    {out, _} = Recording.anonymize(rec, Anonymizer.new())

    assert out["request"]["url"] ==
             "https://api.kick.com/private/v0/channels/900000001/viewer-count"

    assert out["request"]["params"] == %{"ids[]" => 900_000_002}
  end

  test "http: a non-JSON body (e.g. a Cloudflare page) is replaced by a note" do
    rec = %{
      "kind" => "http",
      "request" => %{"method" => "GET", "url" => "https://kick.com/x"},
      "response" => %{"status" => 403, "headers" => [], "body" => "<html>blocked</html>"}
    }

    {out, _} = Recording.anonymize(rec, Anonymizer.new())
    assert out["response"]["body"] == "[non-JSON body, 20 bytes]"
  end

  test "webhook: keeps Kick-Event headers, replaces the signature, anonymizes the body" do
    rec = %{
      "kind" => "webhook",
      "request" => %{
        "method" => "POST",
        "path" => "/",
        "headers" => [
          ["kick-event-message-id", "m1"],
          ["kick-event-signature", "real=="],
          ["x-forwarded-for", "203.0.113.9"],
          ["content-type", "application/json"]
        ],
        "body" => ~s({"follower":{"user_id":9,"username":"fan"}})
      },
      "signature_valid" => true
    }

    {out, _} = Recording.anonymize(rec, Anonymizer.new())
    headers = Map.new(out["request"]["headers"], fn [k, v] -> {k, v} end)

    assert headers["kick-event-message-id"] == "m1"
    assert headers["kick-event-signature"] =~ "removed"
    refute Map.has_key?(headers, "x-forwarded-for")
    assert out["original_signature_valid"] == true
    assert out["anonymized"] == true

    assert Jason.decode!(out["request"]["body"]) == %{
             "follower" => %{"user_id" => 900_000_001, "username" => "user0001"}
           }
  end

  test "pusher: channel names and the JSON string inside data are anonymized" do
    data =
      Jason.encode!(%{"content" => "hello", "sender" => %{"id" => 77, "username" => "chatter"}})

    frame =
      Jason.encode!(%{
        "event" => "App\\Events\\ChatMessageEvent",
        "channel" => "chatrooms.555.v2",
        "data" => data
      })

    {out, _} =
      Recording.pusher_line(
        %{"at" => "t", "direction" => "in", "frame" => frame},
        Anonymizer.new()
      )

    decoded = Jason.decode!(out["frame"])
    assert decoded["event"] == "App\\Events\\ChatMessageEvent"
    assert decoded["channel"] == "chatrooms.900000001.v2"
    inner = Jason.decode!(decoded["data"])
    assert inner["content"] == "text-1"
    assert inner["sender"] == %{"id" => 900_000_002, "username" => "user0001"}
  end

  test "pusher: our own subscribe frame has its channel mapped too, consistently" do
    state = Anonymizer.new()

    sub =
      Jason.encode!(%{
        "event" => "pusher:subscribe",
        "data" => %{"auth" => "", "channel" => "chatrooms.555.v2"}
      })

    {out, state} = Recording.pusher_line(%{"frame" => sub}, state)

    {meta, _} =
      Recording.pusher_line(
        %{"frame" => %{"event" => "connected", "channels" => ["chatrooms.555.v2"]}},
        state
      )

    assert Jason.decode!(out["frame"])["data"]["channel"] == "chatrooms.900000001.v2"
    assert meta["frame"]["channels"] == ["chatrooms.900000001.v2"]
  end
end
