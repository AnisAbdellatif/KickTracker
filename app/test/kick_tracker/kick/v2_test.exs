defmodule KickTracker.Kick.V2Test do
  use ExUnit.Case, async: true

  import KickTracker.Fixtures
  alias KickTracker.Kick.V2

  test "every recorded v2 response gives a follower total and a chatroom id, nothing else" do
    bodies = recorded_bodies("v2/*.json")
    assert bodies != []

    for body <- bodies do
      assert {:ok, kept} = V2.extract(body)
      assert Map.keys(kept) |> Enum.sort() == [:chatroom_id, :followers]
      assert is_integer(kept.followers) and is_integer(kept.chatroom_id)
    end
  end

  test "the follower count as a number or a string; anything else is an error" do
    assert V2.extract(%{"followers_count" => 12}) == {:ok, %{followers: 12, chatroom_id: nil}}
    assert V2.extract(%{"followers_count" => "12"}) == {:ok, %{followers: 12, chatroom_id: nil}}
    assert V2.extract(%{"followers_count" => "12k"}) == {:error, :unexpected_response}
    assert V2.extract(%{"followers_count" => -1}) == {:error, :unexpected_response}
    assert V2.extract(%{}) == {:error, :unexpected_response}
  end
end
