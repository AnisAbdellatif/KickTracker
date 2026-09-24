defmodule KickTracker.Kick.PusherTest do
  use ExUnit.Case, async: true

  alias KickTracker.Kick.Pusher

  @recordings Path.expand("../../../../fixtures/pusher/*.jsonl", __DIR__)

  defp recorded_frames do
    @recordings
    |> Path.wildcard()
    |> Enum.flat_map(&(&1 |> File.stream!() |> Enum.map(fn l -> Jason.decode!(l) end)))
    |> Enum.filter(&(&1["direction"] == "in" and is_binary(&1["frame"])))
    |> Enum.map(& &1["frame"])
  end

  test "every recorded frame decodes; every chat message gives a sender and a time, no text" do
    frames = Enum.map(recorded_frames(), &Pusher.decode/1)
    assert frames != []
    refute :invalid in frames

    chats = for {:chat, m} <- frames, do: m
    assert length(chats) > 100

    for m <- chats do
      assert is_integer(m.sender_id)
      assert %DateTime{time_zone: "Etc/UTC"} = m.at
      assert Map.keys(m) |> Enum.sort() == [:at, :id, :sender_id, :username]
    end

    assert {:connected, 120} in frames
    assert Enum.any?(frames, &match?({:subscribed, "chatrooms." <> _}, &1))
  end

  test "pings, errors and unknown events" do
    assert Pusher.decode(~s({"event":"pusher:ping","data":{}})) == :ping

    assert Pusher.decode(
             ~s({"event":"pusher:error","data":{"code":4001,"message":"App key not in this cluster"}})
           ) ==
             {:error, 4001, "App key not in this cluster"}

    # A raid, say: its name is surfaced, its data is not.
    assert Pusher.decode(
             ~s({"event":"App\\\\Events\\\\SomethingNew","channel":"channel.1","data":"{\\"x\\":1}"})
           ) ==
             {:other, "App\\Events\\SomethingNew", "channel.1"}

    assert Pusher.decode("nope") == :invalid
  end

  test "subscribing, as Kick's own chat does: no auth" do
    assert Jason.decode!(Pusher.subscribe(Pusher.chatroom(5))) == %{
             "event" => "pusher:subscribe",
             "data" => %{"auth" => "", "channel" => "chatrooms.5.v2"}
           }
  end
end
