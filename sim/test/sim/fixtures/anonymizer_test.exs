defmodule Sim.Fixtures.AnonymizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sim.Fixtures.Anonymizer

  defp anon(value), do: Anonymizer.anonymize(value, [], Anonymizer.new())

  test "people's ids, names and pictures are replaced; categories are kept" do
    payload = %{
      "broadcaster" => %{
        "user_id" => 1_234_567,
        "username" => "SomeStreamer",
        "channel_slug" => "somestreamer",
        "profile_picture" => "https://files.kick.com/images/user/1234567/profile.webp"
      },
      "metadata" => %{
        "title" => "Example stream title",
        "category" => %{
          "id" => 15,
          "name" => "Just Chatting",
          "thumbnail" => "https://files.kick.com/c.webp"
        }
      }
    }

    {out, _} = anon(payload)

    assert out["broadcaster"]["user_id"] == 900_000_001
    assert out["broadcaster"]["username"] == "user0001"
    # Same person, different case: same pseudonym.
    assert out["broadcaster"]["channel_slug"] == "user0001"
    assert out["broadcaster"]["profile_picture"] =~ ~r{^https://example\.invalid/asset/\d+$}
    assert out["metadata"]["title"] == "text-1"
    assert out["metadata"]["category"]["id"] == 15
    assert out["metadata"]["category"]["name"] == "Just Chatting"
    refute inspect(out) =~ ~r/somestreamer|1234567|files\.kick\.com/i
  end

  test "the same id maps to the same fake id wherever it appears" do
    {out, _} =
      anon(%{"broadcaster_user_id" => 42, "user" => %{"id" => 42}, "sender" => %{"id" => "42"}})

    assert out["broadcaster_user_id"] == out["user"]["id"]
    assert out["sender"]["id"] == Integer.to_string(out["user"]["id"])
  end

  test "name inside a person is replaced, name elsewhere is kept but reported" do
    {out, state} = anon(%{"sender" => %{"name" => "Someone"}, "gift_box" => %{"name" => "Rose"}})

    assert out["sender"]["name"] == "user0001"
    assert out["gift_box"]["name"] == "Rose"
    assert state.unknown == %{"gift_box.name" => 1}
  end

  test "chat text is replaced, empty text stays empty, the API's top-level message is kept" do
    {out, _} =
      anon(%{
        "message" => "OK",
        "data" => [%{"content" => "salut [emote:1:KEKW]"}, %{"content" => ""}]
      })

    assert out["message"] == "OK"
    assert Enum.map(out["data"], & &1["content"]) == ["text-1", ""]
  end

  test "unknown string fields are reported by path only, never by value" do
    {_, state} = anon(%{"data" => [%{"nickname" => "secret person"}, %{"nickname" => "other"}]})

    assert state.unknown == %{"data.[].nickname" => 2}
    refute inspect(state.unknown) =~ "secret"
  end

  test "timestamps and known-safe fields are not reported" do
    {_, state} =
      anon(%{"created_at" => "2026-09-24T18:02:11Z", "language" => "ar", "event" => "x"})

    assert state.unknown == %{}
  end

  test "pusher channel names get their numbers mapped like ids" do
    state = Anonymizer.new()
    {id, state} = Anonymizer.id(123, state)
    {name, _} = Anonymizer.channel_name("chatrooms.123.v2", state)
    assert name == "chatrooms.#{id}.v2"
  end

  test "a saved mapping gives the same result in a later run" do
    {first, state} = anon(%{"user_id" => 7, "username" => "abc"})
    saved = state |> Anonymizer.to_saved() |> Jason.encode!() |> Jason.decode!()

    {second, _} =
      Anonymizer.anonymize(%{"user_id" => 7, "username" => "ABC"}, [], Anonymizer.new(saved))

    assert first == second
  end

  test "a reply keeps its message ids (UUIDs) but loses who and what" do
    reply = %{
      "id" => "0b5c7e1a-2f3d-4c5b-9a8e-1f2e3d4c5b6a",
      "thread_parent_id" => "9f8e7d6c-5b4a-4321-8765-0fedcba98765",
      "type" => "reply",
      "content" => "agreed",
      "metadata" => %{
        "message_ref" => "1790217929123",
        "original_message" => %{
          "id" => "9f8e7d6c-5b4a-4321-8765-0fedcba98765",
          "content" => "first"
        },
        "original_sender" => %{"id" => 55, "username" => "SomeChatter"}
      },
      "sender" => %{
        "id" => 66,
        "slug" => "otherchatter",
        "identity" => %{
          "badges_v2" => [
            %{
              "badge_type" => "sub",
              "name" => "Subscriber",
              "image_url" => "https://files.kick.com/b.png"
            }
          ]
        }
      }
    }

    {out, state} = anon(reply)

    assert out["id"] == reply["id"]
    assert out["thread_parent_id"] == reply["thread_parent_id"]
    assert out["metadata"]["original_message"]["id"] == reply["thread_parent_id"]
    assert out["metadata"]["message_ref"] == "1790217929123"
    assert out["content"] == "text-1"
    assert out["metadata"]["original_message"]["content"] == "text-2"
    assert out["metadata"]["original_sender"] == %{"id" => 900_000_001, "username" => "user0001"}
    assert out["sender"]["slug"] == "user0002"
    [badge] = out["sender"]["identity"]["badges_v2"]
    assert badge["name"] == "Subscriber"
    assert badge["image_url"] =~ "example.invalid"
    assert state.unknown == %{}
  end

  test "a non-UUID string under an id key is still reported" do
    {_, state} = anon(%{"id" => "not-a-uuid"})
    assert state.unknown == %{"id" => 1}
  end

  test "a Pusher channel name anywhere has its ids mapped" do
    {out, state} =
      anon(%{"data" => %{"channel" => "chatrooms.123.v2"}, "other" => %{"channel" => "general"}})

    assert out["data"]["channel"] == "chatrooms.900000001.v2"
    assert out["other"]["channel"] == "general"
    assert state.unknown == %{"other.channel" => 1}
  end

  test "any *_id number is mapped (e.g. chatroom.chatable_id), except known-safe ones" do
    {out, _} =
      anon(%{
        "id" => 12_345_678,
        "chatroom" => %{"id" => 7777, "chatable_id" => 12_345_678, "category_id" => 15}
      })

    assert out["chatroom"]["chatable_id"] == out["id"]
    assert out["chatroom"]["category_id"] == 15
  end

  test "JSON stored as a string is anonymized inside; chat text that looks like JSON is still text" do
    {out, _} =
      anon(%{
        "data" => ~s({"sender":{"id":4242,"username":"SomeChatter"}}),
        "content" => ~s({"looks":"like json"})
      })

    assert Jason.decode!(out["data"]) == %{
             "sender" => %{"id" => 900_000_001, "username" => "user0001"}
           }

    assert out["content"] == "text-1"
  end

  test "event names and Kick's public key are known-safe, not reported" do
    {out, state} =
      anon(%{
        "events" => [%{"name" => "livestream.status.updated"}],
        "data" => %{"public_key" => "-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----"}
      })

    assert out["events"] == [%{"name" => "livestream.status.updated"}]
    assert state.unknown == %{}
  end

  property "no real person id survives, and the mapping is one to one" do
    check all(ids <- uniq_list_of(integer(1..9_999_999), min_length: 1, max_length: 30)) do
      payload = %{"data" => Enum.map(ids, &%{"sender" => %{"id" => &1, "username" => "u#{&1}"}})}
      {out, _} = Anonymizer.anonymize(payload, [], Anonymizer.new())

      fakes = Enum.map(out["data"], & &1["sender"]["id"])
      assert length(Enum.uniq(fakes)) == length(ids)
      assert Enum.all?(fakes, &(&1 >= 900_000_001))
      names = Enum.map(out["data"], & &1["sender"]["username"])
      assert Enum.all?(names, &String.starts_with?(&1, "user"))
    end
  end

  property "anonymizing is deterministic for a given starting mapping" do
    check all(ids <- list_of(integer(1..1_000), max_length: 20)) do
      payload = %{"data" => Enum.map(ids, &%{"user_id" => &1})}
      assert anon(payload) == anon(payload)
    end
  end
end
