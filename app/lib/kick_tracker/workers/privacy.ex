defmodule KickTracker.Workers.Privacy do
  @moduledoc "Runs a deletion request on the collector (see `KickTracker.Privacy`)."

  use Oban.Worker, queue: :kick, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    result = KickTracker.Privacy.delete(user_id)
    Logger.info("privacy: deleted user #{user_id}: #{inspect(result)}")
    :ok
  end

  # A stuck job gives its slot back.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)
end
