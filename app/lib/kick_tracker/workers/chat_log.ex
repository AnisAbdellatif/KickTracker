defmodule KickTracker.Workers.ChatLog do
  @moduledoc """
  Chat logging's deletions (project.md §12.8), on the collector, which
  owns writes of collected data:

    * `%{"prune" => true}` (hourly): what each channel's retention no
      longer covers;
    * `%{"channel_id", "from", "to"}` (queued by an admin): a channel's log
      over `[from, to)`. Audited where it is queued.
  """

  use Oban.Worker, queue: :kick, max_attempts: 3

  require Logger
  alias KickTracker.ChatLog

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"prune" => true}}) do
    %{messages: m, events: e} = ChatLog.prune()

    if m + e > 0,
      do: Logger.info("chat log: #{m} messages and #{e} events past retention deleted")

    :ok
  end

  def perform(%Oban.Job{args: %{"channel_id" => id, "from" => from, "to" => to}}) do
    {:ok, from, _} = DateTime.from_iso8601(from)
    {:ok, to, _} = DateTime.from_iso8601(to)
    %{messages: m, events: e} = ChatLog.delete_range(id, from, to)

    Logger.info(
      "chat log of channel #{id}: #{m} messages and #{e} events deleted (#{from} – #{to})"
    )

    :ok
  end

  @doc "Queues the deletion of a channel's log over `[from, to)`."
  @spec delete(integer(), DateTime.t(), DateTime.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def delete(channel_id, from, to) do
    %{
      "channel_id" => channel_id,
      "from" => DateTime.to_iso8601(from),
      "to" => DateTime.to_iso8601(to)
    }
    |> new()
    |> Oban.insert()
  end
end
