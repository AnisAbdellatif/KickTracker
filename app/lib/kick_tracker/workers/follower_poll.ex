defmodule KickTracker.Workers.FollowerPoll do
  @moduledoc """
  One follower reading for one channel, from v2 (project.md §3): every 15
  minutes while live, daily while offline (see `FollowerSchedule`), and
  at each stream's start and end. One channel per job, spread out.

  It also stores the channel's chatroom id when it isn't known yet, which
  chat needs. A failed request is a gap in `coverage` (source
  `followers`), never a zero, and isn't retried: the next reading comes on
  schedule.
  """

  use Oban.Worker,
    queue: :followers,
    max_attempts: 1,
    unique: [period: 60, keys: [:channel_id, :reason], states: [:available, :scheduled]]

  require Logger

  alias KickTracker.{Channels, Stats}
  alias KickTracker.Kick.V2
  alias KickTracker.Stats.Coverage

  @coverage_gap_s 1_000

  @doc "Queues a reading for a channel (`reason` for logs and uniqueness)."
  def enqueue(channel_id, reason, opts \\ []) do
    %{channel_id: channel_id, reason: to_string(reason)} |> new(opts) |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id}}) do
    channel = Channels.get!(channel_id)
    at = KickTracker.Metrics.Sessionizer.norm(DateTime.utc_now())

    case V2.channel(channel.slug) do
      {:ok, %{followers: followers, chatroom_id: chatroom_id}} ->
        Stats.insert_samples("follower_samples", [
          %{channel_id: channel.id, observed_at: at, followers: followers}
        ])

        if chatroom_id && chatroom_id != channel.chatroom_id do
          channel = Channels.put_ids(channel, nil, chatroom_id)
          Channels.announce(channel)
        end

        Coverage.mark([channel.id], "followers", true, at, @coverage_gap_s)

      {:error, reason} ->
        Logger.warning("follower reading failed for channel #{channel.id}: #{inspect(reason)}")
        Coverage.mark([channel.id], "followers", false, at, @coverage_gap_s)
    end

    :ok
  end
end
