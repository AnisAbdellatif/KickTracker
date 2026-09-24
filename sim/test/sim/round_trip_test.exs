defmodule Sim.RoundTripTest do
  @moduledoc """
  The recorder, unchanged, pointed at the fake Kick instead of the real one.

  This is what makes the simulator worth having: the same code that records
  the real Kick drives the fake, so anything that only works against the
  simulator shows up here as a failure.
  """

  use ExUnit.Case, async: false

  alias Sim.Recorder.{Config, HTTP, Kick, Store, WebhookCapture, WebhookPolicy}
  alias Sim.{Clock, Instance, Payloads, Scenario, Schedule, Server, StreamState, Webhooks}

  @now ~U[2026-01-05 21:00:00Z]

  setup context do
    scenario =
      Scenario.new(
        channels: [
          [
            slug: "bigstreamer",
            peak_viewers: 5_000,
            schedule: %{days: [1, 3], start_hour: 20, duration_min: 180}
          ],
          [
            slug: "weekender",
            peak_viewers: 50,
            schedule: %{days: [6, 7], start_hour: 14, duration_min: 120}
          ]
        ]
      )

    start_supervised!(
      {Sim.Instance, scenario: scenario, clock: Clock.new(sim_start: @now), port: 0}
    )

    base = Instance.base_url()

    previous =
      for name <- ~w(KICK_API_URL KICK_ID_URL KICK_V2_URL KICK_CLIENT_ID KICK_CLIENT_SECRET),
          do: {name, System.get_env(name)}

    System.put_env(%{
      "KICK_API_URL" => base,
      "KICK_ID_URL" => base,
      "KICK_V2_URL" => base <> "/api/v2",
      "KICK_CLIENT_ID" => "test-id",
      "KICK_CLIENT_SECRET" => "test-secret"
    })

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    run = Store.new_run("round-trip", context.tmp_dir)
    %{config: Config.load("does-not-exist"), run: run, scenario: scenario, base: base}
  end

  @tag :tmp_dir
  test "the recorder's API calls all work against the fake", %{
    config: config,
    run: run,
    scenario: scenario
  } do
    token = Kick.token!(config, run)
    assert is_binary(token)

    assert [channel] = Kick.channels_by_slugs(config, run, token, ["bigstreamer"])
    assert channel["slug"] == "bigstreamer"
    assert channel["stream"]["is_live"] == true

    big = Scenario.channel(scenario, "bigstreamer")
    assert [{_recording, [stream]}] = Kick.livestreams(config, run, token, [big.user_id])
    assert stream["started_at"] == "2026-01-05T20:00:00Z"
    assert stream["viewer_count"] > 0

    assert %{"followers_count" => followers} = Kick.v2_channel(config, run, "bigstreamer")
    assert followers > 0

    # Everything it asked was written down, with no secrets in it.
    recordings = run |> Path.join("**/*.json") |> Path.wildcard()
    assert length(recordings) >= 4
    refute Enum.any?(recordings, &(File.read!(&1) =~ token))
  end

  @tag :tmp_dir
  test "subscriptions round-trip through the recorder's own task code", %{
    config: config,
    run: run,
    scenario: scenario
  } do
    token = Kick.token!(config, run)
    big = Scenario.channel(scenario, "bigstreamer")

    results =
      Kick.subscribe(config, run, token, big.user_id, [
        "livestream.status.updated",
        "channel.followed"
      ])

    assert length(results) == 2
    assert Enum.all?(results, &is_nil(&1["error"]))

    listed = Kick.list_subscriptions(config, run, token)
    assert length(listed) == 2
    assert Enum.all?(listed, &(&1["broadcaster_user_id"] == big.user_id))

    assert Kick.unsubscribe(config, run, token, Enum.map(listed, & &1["id"])) == 204
    assert Kick.list_subscriptions(config, run, token) == []
  end

  @tag :tmp_dir
  test "an offline channel and an unknown one behave like the real API", %{
    config: config,
    run: run
  } do
    token = Kick.token!(config, run)

    assert [weekender] = Kick.channels_by_slugs(config, run, token, ["weekender"])
    assert weekender["stream"]["is_live"] == false
    assert weekender["stream"]["start_time"] == "0001-01-01T00:00:00Z"

    # An unknown slug fails the request, so nothing comes back.
    assert Kick.channels_by_slugs(config, run, token, ["nobody"]) == []

    recording = run |> Path.join("public_api/*channels*.json") |> Path.wildcard() |> List.last()
    assert recording |> File.read!() |> Jason.decode!() |> HTTP.status() == 400
  end

  @tag :tmp_dir
  test "a webhook the fake signs is accepted by the capture plug", %{
    config: config,
    run: run,
    scenario: scenario
  } do
    token = Kick.token!(config, run)
    big = Scenario.channel(scenario, "bigstreamer")
    Kick.subscribe(config, run, token, big.user_id, ["livestream.status.updated"])

    # The capture server the recorder uses, with the fake's own public key.
    {:ok, policy} = WebhookPolicy.start_link([])
    pem = Kick.public_key(config, run, token)
    assert pem == Server.public_key_pem()

    {:ok, server} =
      Bandit.start_link(
        plug: {WebhookCapture, run: run, policy: policy, public_key: pem},
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Webhooks.put_webhook_url("http://127.0.0.1:#{port}/")

    window = Schedule.stream_at(big, @now)
    body = Payloads.status_updated(big, window, @now, true)
    assert Webhooks.deliver(big.user_id, "livestream.status.updated", body, @now) == :ok

    assert eventually(fn -> WebhookPolicy.deliveries(policy) != [] end)

    [recorded] =
      run
      |> Path.join("webhook/*.json")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))

    assert recorded["signature_valid"] == true
    assert recorded["answered"] == 200

    headers = Map.new(recorded["request"]["headers"], fn [k, v] -> {k, v} end)
    assert headers["kick-event-type"] == "livestream.status.updated"
    assert headers["kick-event-version"] == "1"
    assert headers["kick-event-message-id"] =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/

    delivered = Jason.decode!(recorded["request"]["body"])
    assert delivered["is_live"] == true
    assert delivered["started_at"] == "2026-01-05T20:00:00Z"
    assert delivered["broadcaster"]["channel_slug"] == "bigstreamer"
    assert delivered["title"] == StreamState.at(big, window, @now).title
  end

  @tag :tmp_dir
  test "nothing is delivered for an event nobody subscribed to", %{scenario: scenario} do
    big = Scenario.channel(scenario, "bigstreamer")
    Webhooks.put_webhook_url("http://127.0.0.1:1/")

    assert Webhooks.deliver(big.user_id, "channel.followed", %{}, @now) == :ignored
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(20) && {:cont, false}
    end)
  end
end
