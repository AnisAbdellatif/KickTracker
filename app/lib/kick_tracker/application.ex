defmodule KickTracker.Application do
  @moduledoc """
  Starts what this node's role needs (see `KickTracker.Role`): a
  `collector` node never starts the web endpoint, and a `web` node never
  starts collection.
  """

  use Application

  @impl true
  def start(_type, _args) do
    KickTracker.Role.current()
    |> children(collect: Application.get_env(:kick_tracker, :collect, true))
    |> Supervisor.start_link(strategy: :one_for_one, name: KickTracker.Supervisor)
  end

  @doc false
  # What a node with these roles starts. Public for the role tests.
  #
  # `collect: false` leaves collection out even on a collector node: tests
  # start the pieces they need themselves.
  @spec children([KickTracker.Role.t()], keyword()) :: [
          Supervisor.child_spec() | module() | {module(), term()}
        ]
  def children(roles, opts \\ []) do
    collect? = Keyword.get(opts, :collect, true)

    shared(roles) ++
      if(:collector in roles and collect?, do: collector(), else: []) ++
      if(:web in roles, do: web(roles, collect?), else: [])
  end

  # Both roles: telemetry, the database, PubSub (the cluster link that
  # carries live readings from the collector to the site) and Oban, which
  # runs jobs only on a collector.
  defp shared(roles) do
    [
      KickTrackerWeb.Telemetry,
      KickTracker.Repo,
      {DNSCluster, query: Application.get_env(:kick_tracker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: KickTracker.PubSub},
      {Oban, oban(roles)}
    ]
  end

  defp oban(roles) do
    config = Application.fetch_env!(:kick_tracker, Oban)
    if :collector in roles, do: config, else: Keyword.merge(config, queues: false, plugins: false)
  end

  # Collection (project.md §10). The queue consumer comes last, so the
  # channel processes it hands events to are already running.
  defp collector do
    [
      {Registry, keys: :unique, name: KickTracker.Tracking.registry()},
      KickTracker.Kick.PublicKey,
      KickTracker.Kick.Token,
      {DynamicSupervisor,
       name: KickTracker.Tracking.ChannelsSupervisor,
       strategy: :one_for_one,
       max_restarts: 100,
       max_seconds: 60},
      KickTracker.Tracking.Manager,
      KickTracker.Tracking.Poller,
      KickTracker.Events.Consumer
    ]
  end

  # A web node needs its own app token to look channels up for the admin
  # (project.md §13.8) and to list webhook subscriptions on the health page;
  # it is fetched on first use.
  defp web(roles, collect?) do
    # (On a collector the collection tree has it; `collect: false` means
    # tests start it themselves.)
    token = if :collector in roles or not collect?, do: [], else: [KickTracker.Kick.Token]
    token ++ [KickTrackerWeb.Endpoint]
  end

  # Tell Phoenix to update the endpoint configuration whenever the
  # application is updated, when this node serves the site.
  @impl true
  def config_change(changed, _new, removed) do
    if KickTracker.Role.runs?(:web), do: KickTrackerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
