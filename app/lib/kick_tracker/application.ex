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
    |> children()
    |> Supervisor.start_link(strategy: :one_for_one, name: KickTracker.Supervisor)
  end

  @doc false
  # What a node with these roles starts. Public for the role tests.
  @spec children([KickTracker.Role.t()]) :: [
          Supervisor.child_spec() | module() | {module(), term()}
        ]
  def children(roles) do
    shared() ++
      if(:collector in roles, do: collector(), else: []) ++
      if(:web in roles, do: web(), else: [])
  end

  # Both roles: telemetry, the database, and PubSub (the cluster link that
  # carries live readings from the collector to the site).
  defp shared do
    [
      KickTrackerWeb.Telemetry,
      KickTracker.Repo,
      {DNSCluster, query: Application.get_env(:kick_tracker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: KickTracker.PubSub}
    ]
  end

  # The poller, channel processes and queue consumer arrive with the
  # pipeline (project.md §20, steps 9-12).
  defp collector, do: []

  defp web, do: [KickTrackerWeb.Endpoint]

  # Tell Phoenix to update the endpoint configuration whenever the
  # application is updated, when this node serves the site.
  @impl true
  def config_change(changed, _new, removed) do
    if KickTracker.Role.runs?(:web), do: KickTrackerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
