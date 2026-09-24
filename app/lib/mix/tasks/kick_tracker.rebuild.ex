defmodule Mix.Tasks.KickTracker.Rebuild do
  @shortdoc "Recomputes the derived tables from the raw facts"

  @moduledoc """
  Recomputes `stream_stats` and `hourly_stats` from the raw tables
  (project.md §12.6), for everything or for a range:

      mix kick_tracker.rebuild
      mix kick_tracker.rebuild --from 2026-01-01T00:00:00Z --to 2026-02-01T00:00:00Z

  Run after changing a formula. Safe to run at any time: both tables are
  caches, replaced row by row.
  """

  use Mix.Task

  alias KickTracker.Rollups

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [from: :string, to: :string])
    Mix.Task.run("app.config")
    Application.put_env(:kick_tracker, :collect, false)
    Mix.Task.run("app.start")

    {from, to} = range(opts)
    Mix.shell().info("hourly_stats from #{from} to #{to}")

    # A week at a time, so one transaction stays small.
    Stream.iterate(from, &DateTime.add(&1, 7 * 24 * 3600))
    |> Enum.take_while(&DateTime.before?(&1, to))
    |> Enum.each(fn start ->
      finish = Enum.min([DateTime.add(start, 7 * 24 * 3600 - 1), to], DateTime)
      Rollups.hourly(start, finish)
    end)

    n = Rollups.recent_stream_stats(if opts[:from], do: from)
    Mix.shell().info("stream_stats for #{n} streams")
  end

  defp range(opts) do
    from = if f = opts[:from], do: parse!(f), else: earliest() || DateTime.utc_now()
    to = if t = opts[:to], do: parse!(t), else: DateTime.utc_now()
    {from, to}
  end

  # From the earliest raw fact of any kind, not the first stream: chat,
  # follows, support and follower readings before it are in hourly_stats too.
  defp earliest, do: Rollups.earliest_fact()

  defp parse!(s) do
    case DateTime.from_iso8601(s) do
      {:ok, at, _} -> at
      _ -> Mix.raise("not an ISO 8601 time: #{s}")
    end
  end
end
