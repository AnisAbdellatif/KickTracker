defmodule KickTrackerWeb.Plugs.DataToken do
  @moduledoc """
  `/data/v1` answers our own pages only (project.md §13.5): a request needs
  a valid page token in `x-data-token` (`KickTrackerWeb.DataToken`), and a
  browser request must come from our own origin (`Sec-Fetch-Site`, which a
  page on another site can't set). Anything else is a 403 whose body says
  `data_token`, which the chart hook takes as "ask for a new token".
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    token = conn |> get_req_header("x-data-token") |> List.first()

    if same_origin?(conn) and KickTrackerWeb.DataToken.valid?(token) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, ~s({"error":"data_token"}))
      |> halt()
    end
  end

  # Browsers send it on every fetch; a request without it isn't from a
  # browser, and still needs the token.
  defp same_origin?(conn) do
    case get_req_header(conn, "sec-fetch-site") do
      [] -> true
      [site | _] -> site == "same-origin"
    end
  end
end
