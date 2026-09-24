defmodule KickTracker.Collector.Supervisor do
  @moduledoc """
  A collector node's processes (project.md §10.1), in start order:

    1. `Status`, the in-memory state for the endpoint and heartbeat;
    2. `Journal` and `Writer`: writes on local disk, then to Postgres;
    3. `Tracked`, the channel list collection works from;
    4. `Slot`, where `Collection` runs while this node leads, and the
       `Leader` that decides it;
    5. `Heartbeat` and the status endpoint.

  They stop in reverse order: collection stops (flushing chat to the
  journal) and the lease is released before the writer's last drain, so
  a standby takes over while this node finishes writing.
  """

  use Supervisor

  alias KickTracker.Collector

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    port = Collector.config(:status_port)

    children =
      [
        Collector.Status,
        Collector.Journal,
        Supervisor.child_spec(Collector.Writer, shutdown: 20_000),
        Collector.Tracked,
        {DynamicSupervisor, name: Collector.Slot, strategy: :one_for_one},
        Collector.Leader,
        Collector.Heartbeat
      ] ++
        if(port,
          do: [
            {Bandit,
             plug: Collector.StatusPlug, ip: {127, 0, 0, 1}, port: port, startup_log: false}
          ],
          else: []
        )

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 50, max_seconds: 60)
  end
end
