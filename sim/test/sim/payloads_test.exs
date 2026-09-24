defmodule Sim.PayloadsTest do
  use ExUnit.Case, async: true

  alias Sim.{Fixtures, Payloads, Schedule, StreamState}
  alias Sim.Scenario.Channel

  @live ~U[2026-01-05 21:00:00Z]
  @offline ~U[2026-01-06 10:00:00Z]

  defp channel do
    Channel.new(
      slug: "somestreamer",
      peak_viewers: 500,
      language: "ar",
      subscribers: %{active: 72, gifted: 55, canceled: 8},
      schedule: %{days: [1, 3], start_hour: 20, duration_min: 180}
    )
  end

  # Every field the real Kick sent must also be in ours; extra fields of
  # ours are fine (a tracker ignores what it doesn't read).
  defp assert_covers(ours, real, label) do
    missing = MapSet.difference(Fixtures.paths(real), Fixtures.paths(ours))

    assert MapSet.size(missing) == 0,
           "#{label}: the simulator is missing fields the real Kick sent: #{inspect(MapSet.to_list(missing))}"
  end

  describe "shapes match the recordings" do
    test "GET /public/v1/channels" do
      for body <- Fixtures.bodies("public_api/*-channels.json"), real <- body["data"] do
        assert_covers(Payloads.channel(channel(), @live), real, "channels")
      end
    end

    test "GET /public/v1/livestreams" do
      for body <- Fixtures.bodies("public_api/*livestreams-poll*.json"), real <- body["data"] do
        assert_covers(Payloads.livestream(channel(), @live), real, "livestreams")
      end
    end

    test "livestream.status.updated and livestream.metadata.updated webhooks" do
      window = Schedule.stream_at(channel(), @live)

      for real <- Fixtures.webhook_bodies("livestream.status.updated") do
        live? = real["is_live"]
        assert_covers(Payloads.status_updated(channel(), window, @live, live?), real, "status")
      end

      for real <- Fixtures.webhook_bodies("livestream.metadata.updated") do
        assert_covers(Payloads.metadata_updated(channel(), window, @live), real, "metadata")
      end
    end

    test "channel.followed webhook" do
      for real <- Fixtures.webhook_bodies("channel.followed") do
        assert_covers(Payloads.followed(channel(), 900_123), real, "followed")
      end
    end

    test "the fixtures were actually read (otherwise the checks above prove nothing)" do
      assert Fixtures.bodies("public_api/*-channels.json") != []
      assert Fixtures.bodies("public_api/*livestreams-poll*.json") != []
      assert Fixtures.webhook_bodies("livestream.status.updated") != []
      assert Fixtures.webhook_bodies("channel.followed") != []
    end
  end

  describe "live and offline" do
    test "a live channel reports its stream, viewers and current segment" do
      payload = Payloads.channel(channel(), @live)

      assert payload["stream"]["is_live"] == true
      assert payload["stream"]["start_time"] == "2026-01-05T20:00:00Z"
      assert payload["stream"]["viewer_count"] > 0
      assert payload["stream"]["language"] == "ar"
      assert payload["active_subscribers_count"] == 72
      assert payload["stream_title"] != ""
      assert payload["category"]["name"] != nil
    end

    test "an offline channel gets Kick's zero start time, not a missing field" do
      payload = Payloads.channel(channel(), @offline)

      assert payload["stream"]["is_live"] == false
      assert payload["stream"]["start_time"] == "0001-01-01T00:00:00Z"
      assert payload["stream"]["viewer_count"] == 0
      assert payload["stream"]["language"] == ""
      assert payload["stream"]["thumbnail"] == ""
      # Still a channel, still has subscriber counts.
      assert payload["active_subscribers_count"] == 72
    end

    test "livestreams has no entry at all for an offline channel" do
      assert Payloads.livestream(channel(), @live) != nil
      assert Payloads.livestream(channel(), @offline) == nil
    end

    test "v2 carries the follower total, the chatroom id and the doubled channel id" do
      payload = Payloads.v2_channel(channel(), @live)

      assert payload["followers_count"] > 0
      assert payload["chatroom"]["id"] == channel().chatroom_id
      assert payload["chatroom"]["chatable_id"] == payload["id"]
      assert payload["livestream"]["viewer_count"] > 0
      assert Payloads.v2_channel(channel(), @offline)["livestream"] == nil
    end
  end

  describe "quirks a tracker has to cope with" do
    test "metadata repeats the category under both spellings, with the same value" do
      window = Schedule.stream_at(channel(), @live)
      metadata = Payloads.metadata_updated(channel(), window, @live)["metadata"]

      assert metadata["category"] == metadata["Category"]
      assert metadata["category"]["id"] != nil
    end

    test "the end event keeps the stream's start and adds an end" do
      window = Schedule.stream_at(channel(), @live)
      ended = Payloads.status_updated(channel(), window, @live, false)
      started = Payloads.status_updated(channel(), window, @live, true)

      assert started["started_at"] == ended["started_at"]
      assert started["ended_at"] == nil
      assert ended["ended_at"] == "2026-01-05T21:00:00Z"
      assert ended["is_live"] == false
    end

    test "timestamps are whole seconds ending in Z" do
      at = ~U[2026-01-05 21:00:00.123456Z]
      assert Payloads.iso(at) == "2026-01-05T21:00:00Z"
    end

    test "the error envelope's data is an object, like Kick's" do
      assert Payloads.error("Invalid request") == %{"data" => %{}, "message" => "Invalid request"}
      assert Payloads.ok([]) == %{"data" => [], "message" => "OK"}
    end
  end

  describe "stream segments" do
    test "a stream is one to three segments covering it end to end" do
      window = Schedule.stream_at(channel(), @live)
      segments = StreamState.segments(channel(), window)

      assert length(segments) in 1..3
      assert hd(segments).from == window.started_at
      assert List.last(segments).to == window.ends_at

      for [a, b] <- Enum.chunk_every(segments, 2, 1, :discard), do: assert(a.to == b.from)
    end

    test "the segment at a moment is the one running then, and changes exclude the first" do
      window = Schedule.stream_at(channel(), @live)
      segments = StreamState.segments(channel(), window)
      first = hd(segments)

      assert StreamState.at(channel(), window, window.started_at) == first
      assert StreamState.at(channel(), window, DateTime.add(first.to, -1, :second)) == first
      assert StreamState.changes(channel(), window) == tl(segments)
    end

    test "different streams of the same channel tell different stories" do
      monday = Schedule.stream_at(channel(), @live)
      wednesday = Schedule.stream_at(channel(), ~U[2026-01-07 21:00:00Z])

      refute StreamState.segments(channel(), monday) == StreamState.segments(channel(), wednesday)
    end
  end
end
