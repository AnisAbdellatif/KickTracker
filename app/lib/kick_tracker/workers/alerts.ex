defmodule KickTracker.Workers.Alerts do
  @moduledoc "Checks for problems every minute (`KickTracker.Alerts`) and pings the heartbeat."

  use Oban.Worker, queue: :alerts, max_attempts: 1, unique: [period: 50]

  @impl Oban.Worker
  def perform(_job) do
    KickTracker.Alerts.run()
    KickTracker.Alerts.Notifier.heartbeat()
    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(50)
end
