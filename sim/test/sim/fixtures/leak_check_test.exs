defmodule Sim.Fixtures.LeakCheckTest do
  use ExUnit.Case, async: true

  alias Sim.Fixtures.{Anonymizer, LeakCheck}

  @raw %{
    "id" => 12_345_678,
    "slug" => "somestreamer",
    "chatroom" => %{"id" => 7777, "chatable_id" => 12_345_678},
    "user" => %{"username" => "SomeStreamer"},
    "recent_categories" => [%{"id" => 15, "slug" => "just-chatting", "category" => %{"id" => 2}}],
    "data" => ~s({"content":"a real chat message","sender":{"id":4242}})
  }

  test "collects names, long chat texts and 4+ digit ids, including inside nested JSON" do
    sensitive = LeakCheck.sensitive(@raw)

    assert sensitive["somestreamer"] == "slug"
    assert sensitive["SomeStreamer"] == "user.username"
    # Found under both id and chatroom.chatable_id; either path may be reported.
    assert sensitive["12345678"] in ["id", "chatroom.chatable_id"]
    assert sensitive["7777"] == "chatroom.id"
    assert sensitive["a real chat message"] == "data.content"
    assert sensitive["4242"] == "data.sender.id"
    refute Map.has_key?(sensitive, "just-chatting")
    refute Map.has_key?(sensitive, "15")
  end

  test "finds a value anywhere: plain, inside nested JSON, or as a word in a longer string" do
    sensitive = LeakCheck.sensitive(@raw)

    assert LeakCheck.leaks(sensitive, [%{"x" => "https://kick.com/api/v2/channels/somestreamer"}]) ==
             %{"slug" => 1}

    assert map_size(LeakCheck.leaks(sensitive, [%{"body" => ~s({"n":12345678})}])) == 1
    assert LeakCheck.leaks(sensitive, ["user0001", %{"id" => 900_000_001}]) == %{}
  end

  test "string ids and uuids are sensitive too" do
    raw = %{
      "user" => %{"id" => "user_01jzyxwvutsrqponmlkjihg"},
      "video" => %{"uuid" => "0b5c7e1a-2f3d-4c5b-9a8e-1f2e3d4c5b6a"},
      "category_id" => "cat_01jkabcdef"
    }

    sensitive = LeakCheck.sensitive(raw)
    assert sensitive["user_01jzyxwvutsrqponmlkjihg"] == "user.id"
    assert sensitive["0b5c7e1a-2f3d-4c5b-9a8e-1f2e3d4c5b6a"] == "video.uuid"
    refute Map.has_key?(sensitive, "cat_01jkabcdef")

    {out, _} = Anonymizer.anonymize(raw, [], Anonymizer.new())
    assert LeakCheck.leaks(sensitive, [out]) == %{}
  end

  test "UUIDs inside longer strings and order_column numbers are sensitive" do
    raw = %{
      "media" => [
        %{
          "order_column" => 59_143_283,
          "urls" => ["0b5c7e1a-2f3d-4c5b-9a8e-1f2e3d4c5b6a___fullsize_491_276.webp"]
        }
      ]
    }

    sensitive = LeakCheck.sensitive(raw)
    assert sensitive["0b5c7e1a-2f3d-4c5b-9a8e-1f2e3d4c5b6a"] == "media.[].urls.[]"
    assert sensitive["59143283"] == "media.[].order_column"
    # Found even glued to the rest of a file name.
    assert LeakCheck.leaks(sensitive, [raw]) != %{}

    {out, _} = Anonymizer.anonymize(raw, [], Anonymizer.new())
    assert LeakCheck.leaks(sensitive, [out]) == %{}
  end

  test "real_uuids finds UUIDs that aren't the anonymizer's fakes, inside nested JSON too" do
    doc = %{
      "body" => ~s({"media":[{"urls":["0b5c7e1a-2f3d-4c5b-9a8e-1f2e3d4c5b6a___x.webp"]}]}),
      "id" => "00000000-0000-4000-8000-000000000001"
    }

    assert LeakCheck.real_uuids(doc) == %{"body.media.[].urls.[]" => 1}
    assert LeakCheck.real_uuids(%{"id" => "00000000-0000-4000-8000-000000000001"}) == %{}
  end

  test "the anonymizer's output of a v2-like document passes the check" do
    {out, _} = Anonymizer.anonymize(@raw, [], Anonymizer.new())
    assert LeakCheck.leaks(LeakCheck.sensitive(@raw), [out]) == %{}
  end
end
