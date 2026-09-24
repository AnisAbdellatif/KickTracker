defmodule KickTracker.Collector.Heartbeat do
  @moduledoc """
  Every 10s, this collector's row in `collector_nodes`: leading or
  standing by, its epoch, and `KickTracker.Collector.status/0`. The web
  role reads these for the health page and alerts (a dead collector can't
  report itself, §18.2). Best effort: a database that is away only delays
  the row.
  """

  use GenServer
  require Logger

  alias KickTracker.{Collector, Repo}

  @every_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    send(self(), :beat)
    {:ok, %{started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:beat, state) do
    beat(state, nil)
    Process.send_after(self(), :beat, @every_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: beat(state, "stopped")

  defp beat(state, override) do
    status = Collector.status()

    Repo.query!(
      """
      INSERT INTO collector_nodes (id, state, epoch, started_at, heartbeat_at, status)
      VALUES ($1, $2, $3, $4, now(), $5)
      ON CONFLICT (id) DO UPDATE SET state = EXCLUDED.state, epoch = EXCLUDED.epoch,
        started_at = EXCLUDED.started_at, heartbeat_at = now(), status = EXCLUDED.status
      """,
      [status.id, override || status.role, status.epoch, state.started_at, status],
      timeout: 5_000
    )

    :ok
  rescue
    error -> Logger.debug("collector heartbeat not written: #{Exception.message(error)}")
  catch
    :exit, _ -> :ok
  end
end
