defmodule KickTracker.Collector.StatusPlug do
  @moduledoc """
  The collector's own small HTTP endpoint, on `COLLECTOR_STATUS_PORT`
  (loopback only): `GET /healthz` (200 or 503, the container
  healthcheck) and `GET /status` (JSON: role, epoch, journal, sources;
  what the deploy script reads to update the standby first).
  """

  use Plug.Router

  alias KickTracker.Collector

  plug :match
  plug :dispatch

  get "/healthz" do
    if Collector.healthy?(Collector.status()),
      do: send_resp(conn, 200, "ok"),
      else: send_resp(conn, 503, "not collecting")
  end

  get "/status" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Collector.status()))
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
