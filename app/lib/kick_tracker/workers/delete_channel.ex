defmodule KickTracker.Workers.DeleteChannel do
  @moduledoc """
  Deletes everything about a channel (project.md §13.8: "delete data,
  explicit confirmation, typed slug"; §18.3: a streamer asked to be
  removed). Run by the collector; the admin queues it after typing the
  slug. The channel stops being tracked first, so nothing new arrives
  while it runs; its webhook subscriptions go at the next sync.

  Like a privacy deletion, this is an exception to append-only raw facts
  that only a removal request justifies, and it is audited.
  """

  use Oban.Worker, queue: :kick, max_attempts: 3

  require Logger
  alias KickTracker.Repo

  # Children before parents (foreign keys).
  @by_stream ~w(stream_overrides stream_stats chat_stream_users stream_changes)
  @by_channel ~w(viewer_samples chat_minutes chat_minute_users follower_samples subscriber_samples
                 follows support_events channel_events coverage hourly_stats annotations
                 channel_group_members channel_slugs)

  @impl Oban.Worker
  # sobelow_skip ["SQL.Query"]
  def perform(%Oban.Job{args: %{"channel_id" => id}}) do
    case Repo.query!("SELECT kick_user_id, slug FROM channels WHERE id = $1", [id]).rows do
      [[kick_user_id, slug]] ->
        Repo.query!("UPDATE channels SET active = false, public = false WHERE id = $1", [id])
        Phoenix.PubSub.broadcast(KickTracker.PubSub, KickTracker.Channels.topic(), {:removed, id})

        Repo.transaction(
          fn ->
            for t <- @by_stream,
                do:
                  Repo.query!(
                    "DELETE FROM #{t} WHERE stream_id IN (SELECT id FROM streams WHERE channel_id = $1)",
                    [id]
                  )

            Repo.query!(
              "DELETE FROM stream_overrides WHERE other_stream_id IN (SELECT id FROM streams WHERE channel_id = $1)",
              [id]
            )

            for t <- @by_channel, do: Repo.query!("DELETE FROM #{t} WHERE channel_id = $1", [id])
            Repo.query!("DELETE FROM streams WHERE channel_id = $1", [id])

            Repo.query!("DELETE FROM webhook_events WHERE broadcaster_user_id = $1", [
              kick_user_id
            ])

            Repo.query!("DELETE FROM channels WHERE id = $1", [id])
            KickTracker.Removals.record(:channel, kick_user_id)
          end,
          timeout: :infinity
        )

        KickTracker.Workers.SubscriptionSync.enqueue()
        Logger.info("deleted channel #{slug} and all its data")
        :ok

      [] ->
        :ok
    end
  end

  # A stuck job gives its slot back.
  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(1)
end
