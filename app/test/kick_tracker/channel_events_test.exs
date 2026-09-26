defmodule KickTracker.ChannelEventsTest do
  use ExUnit.Case, async: true

  alias KickTracker.ChannelEvents

  @at ~U[2026-01-01 00:00:00.000000Z]

  test "each side of a host has its kind; the event is kept as sent, its figures unknown" do
    received =
      ChannelEvents.raw("App\\Events\\StreamHostEvent", "chatrooms.1.v2", %{"x" => 1}, @at)

    sent =
      ChannelEvents.raw("App\\Events\\ChatMoveToSupportedChannelEvent", "channel.2", %{}, @at)

    assert %{kind: "hosted_by", occurred_at: @at, other_channel: nil, viewers: nil} = received

    assert received.payload == %{
             "event" => "App\\Events\\StreamHostEvent",
             "pusher_channel" => "chatrooms.1.v2",
             "data" => %{"x" => 1}
           }

    assert sent.kind == "hosting"
  end

  test "the same event at the same time has the same key; another time is another host" do
    key = fn at ->
      ChannelEvents.raw("App\\Events\\StreamHostEvent", "c", %{"x" => 1}, at).dedup_key
    end

    assert key.(@at) == key.(@at)
    refute key.(@at) == key.(DateTime.add(@at, 1))
  end
end
