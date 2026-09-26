defmodule KickTracker.Workers.ChannelAvatar do
  @moduledoc """
  Copies channels' pictures (project.md §12.9, `KickTracker.Avatars`):
  `%{"channel_id" => id}` when a channel's picture URL changes, and
  `%{"sweep" => true}` once a day for any not copied yet (a download that
  failed, a picture learnt while jobs were paused).
  """

  use Oban.Worker, queue: :kick, max_attempts: 4, unique: [period: 300, keys: [:channel_id]]

  require Logger
  alias KickTracker.Avatars

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sweep" => true}}) do
    Enum.each(Avatars.stale(), &enqueue/1)
    :ok
  end

  def perform(%Oban.Job{args: %{"channel_id" => id}, attempt: attempt, max_attempts: max}) do
    case Avatars.refresh(id) do
      {:error, reason} when attempt < max ->
        {:error, reason}

      {:error, reason} ->
        # Not a crash worth reporting: the initial stands in, and the daily
        # sweep tries again.
        Logger.warning("channel #{id}: its picture couldn't be copied (#{inspect(reason)})")
        :ok

      _done ->
        :ok
    end
  end

  @doc "Queues a copy of a channel's picture."
  def enqueue(channel_id), do: %{"channel_id" => channel_id} |> new() |> Oban.insert()
end
