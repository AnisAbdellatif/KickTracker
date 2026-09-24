defmodule KickTracker.Workers.ProcessEvents do
  @moduledoc """
  Retries stream status and metadata events still unprocessed a few
  minutes after they were stored (project.md §10): hands them to their
  channel's process again. Events for channels we don't track (any more)
  have nothing to update and are marked processed.

  It pages through **all** of them, oldest first, with a cursor. An active
  channel whose process isn't running keeps its events for the restart;
  they are skipped, and its later events are left out of the next pages,
  so however many a stopped channel has, every other channel's events are
  still reached.
  """

  use Oban.Worker, queue: :kick, max_attempts: 3

  alias KickTracker.{Channels, Events, Tracking}
  alias KickTracker.Events.Handlers

  @page 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    before = DateTime.add(DateTime.utc_now(), -120)
    run(before, nil, MapSet.new(), Map.get(args, "page_size", @page))
  end

  defp run(before, cursor, skipped, size) do
    {envelopes, next} =
      Events.unprocessed_page(before,
        after: cursor,
        exclude: MapSet.to_list(skipped),
        limit: size
      )

    skipped = handle(envelopes, skipped)
    if next, do: run(before, next, skipped, size), else: :ok
  end

  # Returns the broadcasters skipped so far: active channels whose process
  # isn't running.
  defp handle(envelopes, skipped) do
    envelopes
    |> Enum.group_by(&Handlers.broadcaster_id/1)
    |> Enum.reduce(skipped, fn {user_id, envelopes}, skipped ->
      channel = user_id && Channels.get_by_kick_user_id(user_id)

      cond do
        channel == nil or not channel.active ->
          # Nothing will ever process these: the channel isn't tracked.
          Events.mark_processed(Enum.map(envelopes, & &1.message_id))
          skipped

        Tracking.whereis({:channel, user_id}) ->
          Tracking.dispatch(envelopes)
          skipped

        true ->
          MapSet.put(skipped, user_id)
      end
    end)
  end

  # A stuck job gives its slot back.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)
end
