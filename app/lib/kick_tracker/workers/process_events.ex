defmodule KickTracker.Workers.ProcessEvents do
  @moduledoc """
  Retries stream status and metadata events still unprocessed a few
  minutes after they were stored (project.md §10): hands them to their
  channel's process again. Events for channels we don't track (any more)
  have nothing to update and are marked processed.
  """

  use Oban.Worker, queue: :kick, max_attempts: 3

  alias KickTracker.{Channels, Events, Tracking}
  alias KickTracker.Events.Handlers

  @impl Oban.Worker
  def perform(_job) do
    before = DateTime.add(DateTime.utc_now(), -120)

    before
    |> Events.unprocessed_before()
    |> Enum.group_by(&Handlers.broadcaster_id/1)
    |> Enum.each(fn {user_id, envelopes} ->
      channel = user_id && Channels.get_by_kick_user_id(user_id)

      if channel && channel.active && Tracking.whereis({:channel, user_id}),
        do: Tracking.dispatch(envelopes),
        else: untracked(channel, envelopes)
    end)

    :ok
  end

  # Nothing will ever process these: the channel isn't tracked. An active
  # channel whose process isn't running keeps its events for the restart.
  defp untracked(channel, envelopes) do
    if channel == nil or not channel.active,
      do: Events.mark_processed(Enum.map(envelopes, & &1.message_id))
  end

  # A stuck job gives its slot back.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
