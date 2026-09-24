defmodule KickTracker.Workers.FollowerPoll do
  @moduledoc """
  Asks the collecting node for a follower reading of a channel (project.md
  §3), from anywhere: the admin adding a channel on a web node queues this,
  and it runs where collection runs (job queues run only on the leading
  collector, `Collector.Leader`). The reading itself is made by
  `Collector.Sources.Followers`, which spreads requests out.

  If collection is restarting at that moment, the job waits a few seconds
  and tries again.
  """

  use Oban.Worker,
    queue: :followers,
    max_attempts: 5,
    unique: [period: 60, keys: [:channel_id, :reason], states: [:available, :scheduled]]

  alias KickTracker.Collector.Sources.Followers

  @doc "Queues a reading for a channel (`reason` for logs and uniqueness)."
  def enqueue(channel_id, reason, opts \\ []) do
    %{channel_id: channel_id, reason: to_string(reason)} |> new(opts) |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id, "reason" => reason}}) do
    if GenServer.whereis(Followers) do
      Followers.request(channel_id, reason)
    else
      {:snooze, 10}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(10)
end
