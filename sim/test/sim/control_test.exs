defmodule Sim.ControlTest do
  use ExUnit.Case, async: true

  alias Sim.Channel.Timeline
  alias Sim.{Control, Payloads, Scenario, Schedule, StreamState}

  # Monday: an evening stream 20:00-23:00; the weekend channel is off.
  @scenario Scenario.new(
              channels: [
                [slug: "evening", schedule: %{days: [1], start_hour: 20, duration_min: 180}],
                [slug: "weekender", schedule: %{days: [6], start_hour: 14, duration_min: 60}]
              ]
            )
  @morning ~U[2026-01-05 10:00:00Z]
  @evening ~U[2026-01-05 21:00:00Z]

  defp channel(scenario, slug), do: Scenario.channel(scenario, slug)

  describe "going live by hand" do
    test "starts a stream now, for the minutes asked, on an offline channel" do
      assert {:ok, scenario} = Control.go_live(@scenario, "weekender", @morning, 45)
      window = Schedule.stream_at(channel(scenario, "weekender"), @morning)

      assert window.started_at == @morning
      assert window.ends_at == DateTime.add(@morning, 45 * 60, :second)

      refute Schedule.live?(
               channel(scenario, "weekender"),
               DateTime.add(@morning, 46 * 60, :second)
             )

      # The original scenario is untouched: overrides are a new value.
      refute Schedule.live?(channel(@scenario, "weekender"), @morning)
    end

    test "refuses a channel already live, an unknown one, and a silly duration" do
      assert {:error, :already_live} = Control.go_live(@scenario, "evening", @evening, 30)
      assert {:error, :unknown_channel} = Control.go_live(@scenario, "nobody", @morning, 30)
      assert {:error, :bad_minutes} = Control.go_live(@scenario, "weekender", @morning, 0)
    end

    test "the stream it starts produces the usual start events on the next step" do
      state = Timeline.start(channel(@scenario, "weekender"), @morning)
      {:ok, scenario} = Control.go_live(@scenario, "weekender", @morning, 30)

      {emissions, _} = Timeline.advance(channel(scenario, "weekender"), state, @morning)

      assert Enum.map(emissions, &elem(&1, 0)) == [
               "livestream.status.updated",
               "livestream.metadata.updated"
             ]
    end

    test "shows up in the history, like any stream" do
      {:ok, scenario} = Control.go_live(@scenario, "weekender", @morning, 30)

      windows =
        Schedule.windows_between(
          channel(scenario, "weekender"),
          ~U[2026-01-05 00:00:00Z],
          ~U[2026-01-06 00:00:00Z]
        )

      assert [%{started_at: @morning}] = windows
    end
  end

  describe "ending a stream by hand" do
    test "cuts a scheduled stream short, and the end event carries the real end" do
      before = Timeline.start(channel(@scenario, "evening"), @evening)
      assert {:ok, scenario} = Control.go_offline(@scenario, "evening", @evening)

      refute Schedule.live?(channel(scenario, "evening"), DateTime.add(@evening, 1, :second))
      # Before the cut, the stream was running as normal.
      assert Schedule.live?(channel(scenario, "evening"), DateTime.add(@evening, -1, :second))

      {emissions, _} =
        Timeline.advance(channel(scenario, "evening"), before, DateTime.add(@evening, 5, :second))

      assert [{"livestream.status.updated", ended}] = emissions
      assert ended["ended_at"] == Payloads.iso(@evening)
      assert ended["started_at"] == "2026-01-05T20:00:00Z"
    end

    test "ends a stream that was started by hand" do
      {:ok, scenario} = Control.go_live(@scenario, "weekender", @morning, 120)
      later = DateTime.add(@morning, 600, :second)
      assert {:ok, scenario} = Control.go_offline(scenario, "weekender", later)

      refute Schedule.live?(channel(scenario, "weekender"), DateTime.add(later, 1, :second))
      assert Schedule.live?(channel(scenario, "weekender"), DateTime.add(later, -1, :second))
    end

    test "next week's stream is unaffected" do
      {:ok, scenario} = Control.go_offline(@scenario, "evening", @evening)
      assert Schedule.live?(channel(scenario, "evening"), ~U[2026-01-12 21:00:00Z])
    end

    test "refuses a channel that isn't live" do
      assert {:error, :not_live} = Control.go_offline(@scenario, "weekender", @morning)
    end
  end

  describe "changing the title and category" do
    test "takes effect from now, in the API and in the metadata event" do
      {:ok, scenario} =
        Control.set_metadata(@scenario, "evening", @evening, %{
          "title" => "Big announcement",
          "category_id" => 15
        })

      c = channel(scenario, "evening")
      window = Schedule.stream_at(c, @evening)

      assert StreamState.at(c, window, @evening).title == "Big announcement"

      assert StreamState.at(c, window, DateTime.add(@evening, -60, :second)).title !=
               "Big announcement"

      assert Payloads.livestream(c, @evening)["stream_title"] == "Big announcement"
      assert Payloads.metadata_updated(c, window, @evening)["metadata"]["category"]["id"] == 15
    end

    test "only on a live stream, with a known category and something to change" do
      assert {:error, :not_live} =
               Control.set_metadata(@scenario, "weekender", @morning, %{"title" => "x"})

      assert {:error, {:unknown_category, 999}} =
               Control.set_metadata(@scenario, "evening", @evening, %{"category_id" => 999})

      assert {:error, :nothing_to_change} =
               Control.set_metadata(@scenario, "evening", @evening, %{})

      assert {:error, :bad_title} =
               Control.set_metadata(@scenario, "evening", @evening, %{"title" => ""})
    end
  end

  describe "events on demand" do
    test "builds each event type as the scheduled ones would" do
      for {type, event} <- [
            {"follow", "channel.followed"},
            {"sub", "channel.subscription.new"},
            {"resub", "channel.subscription.renewal"},
            {"gift", "channel.subscription.gifts"},
            {"kicks", "kicks.gifted"},
            {"ban", "moderation.banned"},
            {"redemption", "channel.reward.redemption.updated"}
          ] do
        assert {:ok, {^event, body}} = Control.event(@scenario, "evening", type, %{}, @evening)
        assert body["broadcaster"]["channel_slug"] == "evening"
      end
    end

    test "uses the details given" do
      {:ok, {_, gift}} =
        Control.event(
          @scenario,
          "evening",
          "gift",
          %{"count" => 20, "anonymous" => true},
          @evening
        )

      assert length(gift["giftees"]) == 20
      assert gift["gifter"]["is_anonymous"] == true

      {:ok, {_, kicks}} =
        Control.event(
          @scenario,
          "evening",
          "kicks",
          %{"amount" => 500, "user_id" => 42},
          @evening
        )

      assert kicks["gift"]["amount"] == 500
      assert kicks["sender"]["user_id"] == 42

      {:ok, {_, resub}} =
        Control.event(@scenario, "evening", "resub", %{"months" => 12}, @evening)

      assert resub["duration"] == 12
    end

    test "refuses unknown types and bad numbers" do
      assert {:error, {:unknown_event, "raid"}} =
               Control.event(@scenario, "evening", "raid", %{}, @evening)

      assert {:error, {:bad_param, "count"}} =
               Control.event(@scenario, "evening", "gift", %{"count" => 0}, @evening)

      assert {:error, :unknown_channel} =
               Control.event(@scenario, "nobody", "follow", %{}, @evening)
    end
  end

  describe "chat on demand" do
    test "a message from the audience, only while live, never empty" do
      assert {:ok, {_channel, message}} =
               Control.chat(@scenario, "evening", "hello", nil, @evening)

      assert message.content == "hello"
      assert message.sender_id > channel(@scenario, "evening").user_id

      assert {:ok, {_, %{sender_id: 7}}} = Control.chat(@scenario, "evening", "hi", 7, @evening)
      assert {:error, :not_live} = Control.chat(@scenario, "weekender", "hello", nil, @morning)
      assert {:error, :bad_content} = Control.chat(@scenario, "evening", "", nil, @evening)
    end
  end

  describe "faults" do
    test "replaces the fault set, and refuses names it doesn't know" do
      assert {:ok, scenario} =
               Control.set_faults(@scenario, %{
                 "drop_webhooks" => 0.1,
                 "duplicate_webhooks" => nil
               })

      assert scenario.faults == %{drop_webhooks: 0.1}

      assert {:ok, cleared} = Control.set_faults(scenario, %{})
      assert cleared.faults == %{}

      assert {:error, {:unknown_fault, "drop_everything"}} =
               Control.set_faults(@scenario, %{"drop_everything" => 1})
    end
  end
end
