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

  test "every recorded frame decodes; the counted part of a message has a sender and a time, no text" do
    frames = Enum.map(recorded_frames(), &Pusher.decode/1)
    assert frames != []
    refute :invalid in frames

    chats = for {:chat, m, _text} <- frames, do: m
    assert length(chats) > 100

    for m <- chats do
      assert is_integer(m.sender_id)
      assert %DateTime{time_zone: "Etc/UTC"} = m.at
      assert Map.keys(m) |> Enum.sort() == [:at, :id, :sender_id, :username]
    end

    # The text travels apart, for chat logging (§12.8); replies say whom
    # and what they answer.
    texts = for {:chat, _m, t} <- frames, do: t
    assert Enum.all?(texts, &is_binary(&1.content))
    assert Enum.any?(texts, &(&1.type == "message" and &1.reply_to_message_id == nil))

    assert Enum.any?(
             texts,
             &(&1.type == "reply" and is_binary(&1.reply_to_message_id) and
                 is_integer(&1.reply_to_user_id))
           )

    assert {:connected, 120} in frames
    assert Enum.any?(frames, &match?({:subscribed, "chatrooms." <> _}, &1))
  end

  test "pings, errors and unknown events" do
    assert Pusher.decode(~s({"event":"pusher:ping","data":{}})) == :ping

    assert Pusher.decode(
             ~s({"event":"pusher:error","data":{"code":4001,"message":"App key not in this cluster"}})
           ) ==
             {:error, 4001, "App key not in this cluster"}

    # An event we don't parse: its name, and its data for chat logging.
    assert Pusher.decode(
             ~s({"event":"App\\\\Events\\\\SomethingNew","channel":"channel.1","data":"{\\"x\\":1}"})
           ) ==
             {:other, "App\\Events\\SomethingNew", "channel.1", %{"x" => 1}}

    assert Pusher.decode("nope") == :invalid
  end

  test "hosts come out with their data as sent; their fields are not assumed" do
    for name <- Pusher.raw_events() do
      frame =
        Jason.encode!(%{"event" => name, "channel" => "x.1", "data" => ~s({"opaque":[1,2]})})

      assert Pusher.decode(frame) == {:raw, name, "x.1", %{"opaque" => [1, 2]}}
    end

    # Data that isn't JSON is kept as it came.
    frame = Jason.encode!(%{"event" => hd(Pusher.raw_events()), "data" => "not json"})
    assert {:raw, _, nil, "not json"} = Pusher.decode(frame)
  end

  test "subscribing, as Kick's own chat does: no auth" do
    assert Jason.decode!(Pusher.subscribe(Pusher.chatroom(5))) == %{
             "event" => "pusher:subscribe",
             "data" => %{"auth" => "", "channel" => "chatrooms.5.v2"}
           }
  end
end
