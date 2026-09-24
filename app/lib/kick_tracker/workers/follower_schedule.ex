defmodule KickTracker.Workers.FollowerSchedule do
  @moduledoc """
  Every 5 minutes, queues a `FollowerPoll` for each active channel that is
  due: 15 minutes since its last reading while live, a day while offline.
  Each is delayed by a few random minutes so v2 sees one request at a time
  rather than a burst (§14).
  """

  use Oban.Worker, queue: :kick, max_attempts: 1

  alias KickTracker.Repo
  alias KickTracker.Workers.FollowerPoll

  @live_every_s 15 * 60
  @offline_every_s 24 * 3600

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    for {channel_id, live?, last} <- channels() do
      every = if live?, do: @live_every_s, else: @offline_every_s

      if last == nil or DateTime.diff(now, last) >= every - 60 do
        FollowerPoll.enqueue(channel_id, :schedule, schedule_in: :rand.uniform(240))
      end
    end

    :ok
  end

  # Each active channel, whether it has an open stream, and its latest
  # follower reading.
  defp channels do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.id,
             EXISTS (SELECT 1 FROM streams s WHERE s.channel_id = c.id AND s.ended_at IS NULL),
             (SELECT max(f.observed_at) FROM follower_samples f WHERE f.channel_id = c.id)
      FROM channels c
      WHERE c.active
      """)

    Enum.map(rows, &List.to_tuple/1)
  end
end
