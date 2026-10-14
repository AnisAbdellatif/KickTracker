defmodule KickTracker.Kick.V2Test do
  use ExUnit.Case, async: true

  import KickTracker.Fixtures
  alias KickTracker.Kick.V2

  test "every recorded v2 response gives a follower total and a chatroom id, nothing else" do
    bodies = recorded_bodies("v2/*.json")
    assert bodies != []

    for body <- bodies do
      assert {:ok, kept} = V2.extract(200, Jason.encode!(body))
      assert Map.keys(kept) |> Enum.sort() == [:chatroom_id, :followers]
      assert kept.followers >= 0 and is_integer(kept.chatroom_id)
    end
  end

  test "the follower count as a number or a string; anything else is an error" do
    answer = fn followers ->
      Jason.encode!(%{"id" => 2, "followers_count" => followers, "chatroom" => %{"id" => 3}})
    end

    assert V2.extract(200, answer.(12)) == {:ok, %{followers: 12, chatroom_id: 3}}
    assert V2.extract(200, answer.("12")) == {:ok, %{followers: 12, chatroom_id: 3}}
    assert V2.extract(200, answer.("12k")) == {:error, :unexpected_response}
    assert V2.extract(200, answer.(-1)) == {:error, :unexpected_response}
    assert V2.extract(200, answer.(nil)) == {:error, :unexpected_response}
    assert V2.extract(200, "{}") == {:error, :unexpected_response}
    assert V2.extract(200, "<html>") == {:error, :unexpected_response}
  end

  test "an error keeps only the status: the body may hold the signed playback URL" do
    assert V2.extract(404, ~s({"playback_url":"https://x.invalid/?token=secret"})) ==
             {:error, {:http, 404}}
  end
end
