defmodule KickTracker.Collector.Collection do
  @moduledoc """
  Everything that collects, started only on the leading collector
  (project.md §10.1): the channel processes (via the Manager), the polled
  sources, and the webhook consumer (last, so the channel processes it
  hands events to are running; not on a shadow, §10.5).

  If this tree gives up (too many crashes), `Collector.Leader` restarts it
  after a backoff: collection problems never take the node down.
  """

  use Supervisor

  alias KickTracker.Collector.Sources.{Followers, Subscribers, Viewers}
  alias KickTracker.Collector.SourceRunner

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary,
      shutdown: 25_000
    }

  @impl true
  def init(opts) do
    # A shadow (§10.5) polls and chats but takes no webhooks and manages no
    # subscriptions: those are the primary side's.
    shadow? = KickTracker.Collector.mode() == :shadow

    # A node that also serves the site already runs a token.
    token =
      if GenServer.whereis(KickTracker.Kick.Token), do: [], else: [KickTracker.Kick.Token]

    manager =
      if shadow?,
        do: {KickTracker.Tracking.Manager, on_change: fn -> :ok end},
        else: KickTracker.Tracking.Manager

    sources =
      for source <- Keyword.get(opts, :sources, [Viewers, Subscribers, Followers]),
          do: {SourceRunner, source}

    consumer =
      if Keyword.get(opts, :consumer, not shadow?), do: [KickTracker.Events.Consumer], else: []

    children =
      [
        {Registry, keys: :unique, name: KickTracker.Tracking.registry()},
        {Task.Supervisor, name: KickTracker.Collector.Tasks},
        KickTracker.Kick.PublicKey
      ] ++
        token ++
        [
          Supervisor.child_spec(
            {DynamicSupervisor,
             name: KickTracker.Tracking.ChannelsSupervisor,
             strategy: :one_for_one,
             max_restarts: 100,
             max_seconds: 60},
            shutdown: 20_000
          ),
          manager
        ] ++ sources ++ consumer

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 30, max_seconds: 60)
  end
end
