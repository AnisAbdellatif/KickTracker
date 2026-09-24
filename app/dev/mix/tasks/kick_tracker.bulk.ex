defmodule Mix.Tasks.KickTracker.Bulk do
  @shortdoc "Writes months of simulated history into the raw tables (development only)"

  @moduledoc """
  Bulk mode (project.md §20, step 13b): history from the fake Kick,
  written straight into the database, for building the site on realistic
  data.

      mix kick_tracker.bulk                         # 90 days up to now, default scenario
      mix kick_tracker.bulk --days 30 --no-chat
      mix kick_tracker.bulk --scenario ../sim/scenarios/busy.exs --to 2026-09-01T00:00:00Z

  Development only (it lives in `dev/`). Meant for an empty development
  database; the channels are the scenario's (see `Sim.Scenarios`).
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [days: :integer, to: :string, scenario: :string, chat: :boolean]
      )

    Mix.Task.run("app.config")
    # Only the database: no polling, no queue, nothing talking to any Kick.
    Application.put_env(:kick_tracker, :collect, false)
    Mix.Task.run("app.start")
    # Every insert at debug level would drown the progress lines.
    Logger.configure(level: :info)

    scenario =
      if path = opts[:scenario], do: Sim.Scenarios.load!(path), else: Sim.Scenarios.default()

    to =
      case opts[:to] do
        nil -> DateTime.utc_now()
        s -> s |> DateTime.from_iso8601() |> elem(1)
      end

    from = DateTime.add(to, -Keyword.get(opts, :days, 90) * 86_400)
    Mix.shell().info("bulk: #{length(scenario.channels)} channels, #{from} to #{to}")

    started = System.monotonic_time(:second)

    totals =
      KickTracker.Bulk.run(scenario, from, to,
        chat: Keyword.get(opts, :chat, true),
        log: &Mix.shell().info/1
      )

    Mix.shell().info(
      "done in #{System.monotonic_time(:second) - started}s: #{totals.streams} streams, " <>
        "#{totals.samples} viewer samples, #{totals.messages} chat messages"
    )
  end
end
