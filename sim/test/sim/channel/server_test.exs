defmodule Sim.Channel.ServerTest do
  @moduledoc """
  A whole simulated stream, from going live to ending, delivered as real
  signed webhooks into the recorder's own capture plug. If the two halves
  of this project ever stop agreeing, this is where it shows.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Sim.Channel.Server, as: ChannelServer
  alias Sim.Recorder.{Store, WebhookCapture, WebhookPolicy}
  alias Sim.{Channels, Clock, Instance, Scenario, Server, Webhooks}

  @slug "somestreamer"
  # Monday, half a minute before a three-hour stream starts.
  @before ~U[2026-01-05 19:59:30Z]

  setup context do
    scenario =
      Scenario.new(
        channels: [
          [
            slug: @slug,
            peak_viewers: 2_000,
            schedule: %{days: [1], start_hour: 20, duration_min: 180}
          ]
        ]
      )

    # tick_ms: 0 stops the timer, so each test steps time itself.
    start_supervised!(
      {Instance, scenario: scenario, clock: Clock.new(sim_start: @before), port: 0, tick_ms: 0}
    )

    run = Store.new_run("channel", context.tmp_dir)
    {:ok, policy} = WebhookPolicy.start_link([])

    {:ok, server} =
      Bandit.start_link(
        plug: {WebhookCapture, run: run, policy: policy, public_key: Server.public_key_pem()},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    channel = Scenario.channel(scenario, @slug)

    Webhooks.subscribe(
      channel.user_id,
      Enum.map(Webhooks.event_types(), &%{"name" => &1, "version" => 1})
    )

    Webhooks.put_webhook_url("http://127.0.0.1:#{port}/")
    wait_for(fn -> ChannelServer.whereis(@slug) != nil end)

    %{run: run, policy: policy, channel: channel}
  end

  defp at(seconds_from_start),
    do: Server.put_clock(Clock.new(sim_start: DateTime.add(@before, seconds_from_start, :second)))

  defp captured(run) do
    run
    |> Path.join("webhook/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  defp event_of(recording) do
    Enum.find_value(recording["request"]["headers"], fn [k, v] ->
      if k == "kick-event-type", do: v
    end)
  end

  defp wait_for(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(20) && {:cont, false}
    end)
  end

  test "the channel's process is registered under its slug" do
    assert Channels.running() == [@slug]
    assert is_pid(ChannelServer.whereis(@slug))
    assert ChannelServer.whereis("SOMESTREAMER") == ChannelServer.whereis(@slug)
  end

  test "a stream going live and ending arrives as signed webhooks", %{run: run, policy: policy} do
    # Before it starts: nothing to say.
    assert ChannelServer.tick(@slug) == []

    at(60)

    assert ChannelServer.tick(@slug) == [
             "livestream.status.updated",
             "livestream.metadata.updated"
           ]

    at(3 * 3600 + 120)
    assert "livestream.status.updated" in ChannelServer.tick(@slug)

    statuses = fn ->
      for recording <- captured(run),
          event_of(recording) == "livestream.status.updated",
          do: Jason.decode!(recording["request"]["body"])
    end

    assert wait_for(fn -> length(statuses.()) == 2 end)
    assert WebhookPolicy.deliveries(policy) != []

    recordings = captured(run)

    # Every delivery verified against the simulator's own key.
    assert Enum.all?(recordings, &(&1["signature_valid"] == true))
    assert Enum.all?(recordings, &(&1["answered"] == 200))

    assert [live, ended] = Enum.sort_by(statuses.(), &(&1["is_live"] == false))
    assert live["is_live"] == true and live["ended_at"] == nil
    assert ended["is_live"] == false
    assert ended["started_at"] == live["started_at"]
    assert ended["ended_at"] == "2026-01-05T23:00:00Z"
  end

  test "an hour of a stream produces the events a tracker has to handle", %{
    run: run,
    policy: policy
  } do
    at(60)
    ChannelServer.tick(@slug)

    for minute <- 1..60 do
      at(60 + minute * 60)
      ChannelServer.tick(@slug)
    end

    assert wait_for(fn -> length(WebhookPolicy.deliveries(policy)) >= 20 end)

    kinds = run |> captured() |> Enum.map(&event_of/1) |> Enum.frequencies()

    assert kinds["livestream.status.updated"] == 1
    assert kinds["channel.followed"] > 5
    assert Map.keys(kinds) -- Sim.Webhooks.event_types() == []

    assert Enum.all?(captured(run), &(&1["signature_valid"] == true))
  end

  test "restarting a channel mid-stream doesn't re-announce it", %{run: run, policy: policy} do
    at(60)
    ChannelServer.tick(@slug)
    assert wait_for(fn -> WebhookPolicy.deliveries(policy) != [] end)
    before = length(captured(run))

    pid = ChannelServer.whereis(@slug)
    Process.exit(pid, :kill)

    assert wait_for(fn ->
             is_pid(ChannelServer.whereis(@slug)) and ChannelServer.whereis(@slug) != pid
           end)

    at(120)
    refute "livestream.status.updated" in ChannelServer.tick(@slug)

    Process.sleep(100)
    statuses = run |> captured() |> Enum.count(&(event_of(&1) == "livestream.status.updated"))
    assert statuses == 1
    assert length(captured(run)) >= before
  end

  test "with nothing subscribed, nothing is delivered", %{run: run, channel: channel} do
    Webhooks.unsubscribe(Enum.map(Webhooks.list(), & &1["id"]))

    at(60)
    assert ChannelServer.tick(@slug) != []
    assert Webhooks.subscription_for(channel.user_id, "livestream.status.updated") == nil

    Process.sleep(100)
    assert captured(run) == []
  end

  test "channels can be started and stopped at runtime", %{channel: channel} do
    assert Channels.stop_channel(@slug) == :ok
    assert wait_for(fn -> Channels.running() == [] end)
    assert Channels.stop_channel(@slug) == {:error, :not_found}

    assert {:ok, _pid} = Channels.start_channel(channel, tick_ms: 0)
    assert wait_for(fn -> Channels.running() == [@slug] end)
  end
end
