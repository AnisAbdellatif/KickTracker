defmodule KickTracker.Alerts.Ticker do
  @moduledoc """
  Checks alerts every minute from a web node (project.md §18.2). The
  leading collector checks them too (`Workers.Alerts`); a check takes a
  database lock, so the two never notify twice. Running here as well is
  what makes a dead or stuck collector noticed: it can't report itself.
  """

  use GenServer
  require Logger

  @every_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, true), do: Process.send_after(self(), :check, @every_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @every_ms)
    KickTracker.Alerts.run()
    {:noreply, state}
  rescue
    error ->
      Logger.warning("alert check failed: #{Exception.message(error)}")
      {:noreply, state}
  end
end
