defmodule KickTrackerWeb.HealthzController do
  @moduledoc """
  `GET /healthz` for external uptime checks and the load balancer
  (project.md §18.2): 200 when the site can reach its database, 503
  otherwise. Says nothing else.
  """

  use KickTrackerWeb, :controller

  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(KickTracker.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> send_resp(conn, 200, "ok")
      {:error, _} -> send_resp(conn, 503, "database unavailable")
    end
  end
end
