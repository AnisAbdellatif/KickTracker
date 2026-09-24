defmodule Mix.Tasks.Sim do
  @shortdoc "Runs the fake Kick"

  @moduledoc """
  Starts the simulator and keeps it running: the token endpoint, the public
  API, the v2 channel endpoint and webhook delivery, all on one port.

      mix sim
      mix sim --port 4050 --speed 60 --from 2026-01-01T00:00:00Z
      mix sim --scenario scenarios/busy.exs --webhook-url http://localhost:4040/

  Options:

    * `--port` — the port to listen on (default 4050)
    * `--scenario` — a scenario file (default: `Sim.Scenarios.default/0`)
    * `--speed` — how many simulated seconds pass per real second
    * `--from` — where simulated time starts (ISO 8601), for generating history
    * `--webhook-url` — where to deliver webhooks; without it, nothing is
      delivered and the API still works

  Point the code under test at it:

      KICK_API_URL=http://127.0.0.1:4050
      KICK_ID_URL=http://127.0.0.1:4050
      KICK_V2_URL=http://127.0.0.1:4050/api/v2
  """

  use Mix.Task

  alias Sim.{Clock, Instance, Scenarios}

  @switches [
    port: :integer,
    scenario: :string,
    speed: :float,
    from: :string,
    webhook_url: :string
  ]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    scenario = if path = opts[:scenario], do: Scenarios.load!(path), else: Scenarios.default()

    clock =
      Clock.new(
        sim_start: parse_from(opts[:from]),
        speed: Keyword.get(opts, :speed, 1)
      )

    {:ok, _} =
      Instance.start_link(
        scenario: scenario,
        clock: clock,
        port: Keyword.get(opts, :port, 4050),
        webhook_url: opts[:webhook_url]
      )

    base = Instance.base_url()
    Mix.shell().info("fake Kick on #{base}")
    Mix.shell().info("  KICK_API_URL=#{base} KICK_ID_URL=#{base} KICK_V2_URL=#{base}/api/v2")
    Mix.shell().info("  webhooks -> #{opts[:webhook_url] || "(nowhere: pass --webhook-url)"}")
    Mix.shell().info("  simulated now: #{Sim.Server.now()} (speed #{clock.speed}x)")

    for channel <- scenario.channels do
      live = if Sim.Schedule.live?(channel, Sim.Server.now()), do: "live", else: "offline"

      Mix.shell().info(
        "  #{String.pad_trailing(channel.slug, 16)} #{channel.peak_viewers} viewers, #{live}"
      )
    end

    Process.sleep(:infinity)
  end

  defp parse_from(nil), do: DateTime.utc_now()

  defp parse_from(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      {:error, reason} -> Mix.raise("bad --from #{inspect(value)}: #{inspect(reason)}")
    end
  end
end
