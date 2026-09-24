defmodule KickTrackerWeb.Data.JSON do
  @moduledoc """
  Sends `/data/v1` responses (project.md §13.5): JSON with an ETag, and a
  `Cache-Control` that lets Caddy or Cloudflare serve repeats. A range
  still moving (it reaches into the last two days, which the rollups and
  late events may still change) is cached 30 seconds; an older one a day.
  """

  import Plug.Conn

  @recent_s 2 * 86_400

  @spec send(Plug.Conn.t(), term(), DateTime.t()) :: Plug.Conn.t()
  def send(conn, data, to) do
    body = Jason.encode_to_iodata!(data)

    etag =
      ~s(W/") <>
        (:crypto.hash(:sha256, body) |> binary_part(0, 12) |> Base.url_encode64(padding: false)) <>
        ~s(")

    max_age =
      if DateTime.diff(DateTime.utc_now(), to) < @recent_s, do: 30, else: 86_400

    conn =
      conn
      |> put_resp_header("cache-control", "public, max-age=#{max_age}")
      |> put_resp_header("etag", etag)
      |> put_resp_content_type("application/json")

    if etag in get_req_header(conn, "if-none-match"),
      do: send_resp(conn, 304, ""),
      else: send_resp(conn, 200, body)
  end

  @doc "A 404 with a JSON body."
  def not_found(conn),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, ~s({"error":"not found"}))
end
