defmodule KickTracker.ChannelEventsTest do
  use ExUnit.Case, async: true

  alias KickTracker.ChannelEvents
  import KickTracker.Fixtures, only: [recorded_hosts: 0]

  @at ~U[2026-01-01 00:00:00.000000Z]
  @received "App\\Events\\StreamHostEvent"
  @sent "App\\Events\\ChatMoveToSupportedChannelEvent"

  test "recorded hosts: who and how many, on both sides of one host" do
    rows = for {n, c, d, at} <- recorded_hosts(), do: ChannelEvents.row(n, c, d, at)

    assert length(rows) == 4
    assert Enum.all?(rows, &(is_binary(&1.other_channel) and is_integer(&1.viewers)))

    # One host between two tracked channels, seen from both ends: the
    # receiving side names the host by username, the hosting side the
    # hosted channel by slug, and both count the same viewers.
    [received] = for r <- rows, r.kind == "hosted_by", r.viewers == 542, do: r
    [sent] = for r <- rows, r.kind == "hosting", do: r
    assert sent.viewers == 542
    assert abs(DateTime.diff(sent.occurred_at, received.occurred_at, :millisecond)) < 1000
    assert sent.payload["data"]["hosted"]["slug"] == sent.other_channel
  end

  test "only what is read is kept: no playback URL, livestream, pictures or free text" do
    for {n, c, d, at} <- recorded_hosts() do
      row = ChannelEvents.row(n, c, d, at)
      assert %{"event" => ^n, "pusher_channel" => ^c, "data" => data} = row.payload

      case row.kind do
        "hosted_by" ->
          assert Map.keys(data) == ~w(chatroom_id host_username number_viewers)

        "hosting" ->
          assert Map.keys(data) == ~w(hosted slug)
          assert Map.keys(data["hosted"]) == ~w(slug username viewers_count)
      end

      refute Jason.encode!(row.payload) =~ ~r/playback|livestream|thumbnail|profile_pic|optional/
    end
  end

  test "each side of a host has its kind; a figure missing or of another type stays unknown" do
    received = ChannelEvents.row(@received, "chatrooms.1.v2", %{"x" => 1}, @at)
    sent = ChannelEvents.row(@sent, "channel.2", %{}, @at)

    assert %{kind: "hosted_by", occurred_at: @at, other_channel: nil, viewers: nil} = received
    assert %{kind: "hosting", other_channel: nil, viewers: nil} = sent

    odd = %{"host_username" => "", "number_viewers" => "12"}
    assert %{other_channel: nil, viewers: nil} = ChannelEvents.row(@received, "c", odd, @at)

    negative = %{"host_username" => 5, "number_viewers" => -1}
    assert %{other_channel: nil, viewers: nil} = ChannelEvents.row(@received, "c", negative, @at)

    # The hosted channel's slug, from inside `hosted` when not beside it.
    nested = %{"hosted" => %{"slug" => "somestreamer", "viewers_count" => 0}}

    assert %{other_channel: "somestreamer", viewers: 0} =
             ChannelEvents.row(@sent, "c", nested, @at)

    # Data that wasn't JSON (kept as it came by the decoder) reads as nothing.
    assert %{other_channel: nil, viewers: nil, payload: %{"data" => %{"host_username" => nil}}} =
             ChannelEvents.row(@received, nil, "not json", @at)
  end

  test "the same event at the same time has the same key; another time is another host" do
    key = fn at -> ChannelEvents.row(@received, "c", %{"x" => 1}, at).dedup_key end

    assert key.(@at) == key.(@at)
    refute key.(@at) == key.(DateTime.add(@at, 1))
  end

  test "the key is hashed from the event as sent, as before parsing, so stored rows still match" do
    data = %{"host_username" => "someone", "number_viewers" => 3, "optional_message" => "hi"}
    payload = %{"event" => @received, "pusher_channel" => "c", "data" => data}

    before =
      :crypto.hash(:sha256, [DateTime.to_iso8601(@at), 0, Jason.encode!(payload)])
      |> Base.encode16(case: :lower)

    assert ChannelEvents.row(@received, "c", data, @at).dedup_key == before
  end
end
