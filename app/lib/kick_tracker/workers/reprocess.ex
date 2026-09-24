defmodule KickTracker.Workers.Reprocess do
  @moduledoc """
  Admin reprocessing (project.md §13.8), run by the collector (the web
  role writes no collected data):

    * `%{"kind" => "rollups", "from", "to"}`: recomputes `hourly_stats`
      for the range and `stream_stats` for streams overlapping it (and any
      `"stream_ids"` given, after a correction);
    * `%{"kind" => "replay", "from", "to", "channel_id"}`: runs stored
      `webhook_events` through the current handlers again: facts are
      upserts, so existing rows stay as they are and missing ones appear;
      stream status and metadata go to the channel's process, whose rules
      don't depend on arrival order.
  """

  use Oban.Worker, queue: :kick, max_attempts: 3

  import Ecto.Query
  require Logger

  alias KickTracker.{Events, Repo, Rollups, Tracking}
  alias KickTracker.Events.{Handlers, WebhookEvent}

  @doc "Queues a job; returns the Oban insert result."
  def enqueue(args), do: args |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "rollups"} = args}) do
    {from, to} = range(args)
    Rollups.hourly(from, to)

    ids =
      Repo.all(
        from s in "streams",
          where: s.started_at < ^to and (is_nil(s.ended_at) or s.ended_at > ^from),
          select: s.id
      )

    (ids ++ Map.get(args, "stream_ids", [])) |> Enum.uniq() |> Enum.each(&Rollups.stream_stats/1)
    Logger.info("reprocess: rollups from #{from} to #{to}, #{length(ids)} streams")
    :ok
  end

  def perform(%Oban.Job{args: %{"kind" => "replay"} = args}) do
    {from, to} = range(args)
    channel = args["channel_id"] && KickTracker.Channels.get!(args["channel_id"])

    query =
      from e in WebhookEvent,
        where: e.occurred_at >= ^from and e.occurred_at < ^to,
        # Redacted for a deletion request: never replayed.
        where: is_nil(e.redacted_at),
        order_by: [asc: e.occurred_at]

    query =
      if channel,
        do: where(query, [e], e.broadcaster_user_id == ^channel.kick_user_id),
        else: query

    Repo.transaction(
      fn ->
        query
        |> Repo.stream(max_rows: 500)
        |> Stream.map(&Events.to_envelope/1)
        |> Stream.chunk_every(500)
        |> Enum.each(fn batch ->
          Handlers.write_facts(batch)
          Tracking.dispatch(Enum.filter(batch, &Handlers.channel_state?/1))
        end)
      end,
      timeout: :infinity
    )

    :ok
  end

  defp range(%{"from" => from, "to" => to}) do
    {:ok, from, _} = DateTime.from_iso8601(from)
    {:ok, to, _} = DateTime.from_iso8601(to)
    {from, to}
  end
end
