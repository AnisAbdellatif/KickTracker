defmodule KickTracker.Workers.Rollups do
  @moduledoc """
  Keeps the derived tables current (project.md §12.6). Every 5 minutes:
  the last 3 hours of `hourly_stats`, and `stream_stats` for streams live
  or ended in that time. Once a night (`%{"hours" => 48}`): the last two
  days, for facts that arrived late.
  """

  use Oban.Worker, queue: :kick, max_attempts: 3, unique: [period: 240]

  alias KickTracker.Rollups

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    hours = Map.get(args, "hours", 3)
    now = DateTime.utc_now()
    since = DateTime.add(now, -hours * 3600)

    Rollups.hourly(since, now)
    Rollups.recent_stream_stats(since)
    :ok
  end
end
