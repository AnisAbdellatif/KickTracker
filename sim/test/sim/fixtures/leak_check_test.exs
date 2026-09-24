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

  test "the anonymizer's output of a v2-like document passes the check" do
    {out, _} = Anonymizer.anonymize(@raw, [], Anonymizer.new())
    assert LeakCheck.leaks(LeakCheck.sensitive(@raw), [out]) == %{}
  end
end
