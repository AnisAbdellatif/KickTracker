defmodule KickTracker.Application do
  @moduledoc """
  Starts what this node's role needs (see `KickTracker.Role`): a
  `collector` node never starts the web endpoint, and a `web` node never
  starts collection.
  """

  use Application

  @impl true
  def start(_type, _args) do
    KickTracker.ErrorLogger.install()
    KickTracker.Alerts.attach_error_notifications()

    KickTracker.Role.current()
    |> children(collect: Application.get_env(:kick_tracker, :collect, true))
    # Generous limits: a child in trouble is restarted, never the node
    # (collection has its own, stricter isolation in `Collector.Supervisor`).
    |> Supervisor.start_link(
      strategy: :one_for_one,
      name: KickTracker.Supervisor,
      max_restarts: 20,
      max_seconds: 60
    )
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
  # runs jobs only on the leading collector (`Collector.Leader` resumes
  # its queues; they start paused).
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

    cond do
      :collector not in roles -> Keyword.merge(config, queues: false, plugins: false)
      KickTracker.Collector.mode() == :shadow -> Keyword.put(config, :plugins, shadow_plugins())
      true -> config
    end
  end

  # A shadow (§10.5) runs only its own jobs: copying the channel list and
  # removals from the primary side, and pruning what it no longer needs.
  defp shadow_plugins do
    [
      {Oban.Plugins.Pruner, max_age: 7 * 24 * 3600},
      {Oban.Plugins.Cron,
       crontab: [
         {"* * * * *", KickTracker.Workers.ShadowSync},
         {"33 3 * * *", KickTracker.Workers.ShadowSync, args: %{"kind" => "prune"}}
       ]}
    ]
  end

  # Collection (project.md §10.1): the journal, the leader election, and
  # the collection tree while this node leads.
  defp collector, do: [KickTracker.Collector.Supervisor]

  # A web node needs its own app token to look channels up for the admin
  # (project.md §13.8) and to list webhook subscriptions on the health page;
  # it is fetched on first use. (A node that also collects shares it with
  # its collection tree, which only has one while it leads; `collect:
  # false` means tests start it themselves.)
  defp web(_roles, collect?) do
    token = if collect?, do: [KickTracker.Kick.Token], else: []

    token ++
      [
        KickTracker.Cache,
        KickTrackerWeb.Plugs.RateLimit.storage_child(),
        # Alerts are checked from here too, so a dead collector is noticed.
        {KickTracker.Alerts.Ticker, enabled: collect?},
        KickTrackerWeb.Endpoint
      ]
  end

  # Tell Phoenix to update the endpoint configuration whenever the
  # application is updated, when this node serves the site.
  @impl true
  def config_change(changed, _new, removed) do
    if KickTracker.Role.runs?(:web), do: KickTrackerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
