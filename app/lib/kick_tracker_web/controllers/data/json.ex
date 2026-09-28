defmodule KickTrackerWeb.Data.JSON do
  @moduledoc """
  Sends `/data/v1` responses (project.md §13.5): JSON with an ETag, and a
  `Cache-Control` for the browser only (`private`: a shared cache would
  serve it without the page token `Plugs.DataToken` checks). A range
  that reaches now (a live stream, a rolling period) is revalidated every
  time: a chart refreshing it must see each new reading, and an unchanged
  answer is a 304. A range still moving otherwise (it reaches into the
  last two days, which the rollups and late events may still change) is
  cached 30 seconds; an older one a day. `shared: true` keeps 30 seconds
  for a range that reaches now, for an answer whose URL already changes
  with each minute (the sparklines).
  """

  import Plug.Conn

  @recent_s 2 * 86_400
  # A range ending this close to now is still being written.
  @now_s 120

  @spec send(Plug.Conn.t(), term(), DateTime.t(), keyword()) :: Plug.Conn.t()
  def send(conn, data, to, opts \\ []) do
    body = Jason.encode_to_iodata!(data)

    etag =
      ~s(W/") <>
        (:crypto.hash(:sha256, body) |> binary_part(0, 12) |> Base.url_encode64(padding: false)) <>
        ~s(")

    age = DateTime.diff(DateTime.utc_now(), to)

    cache =
      cond do
        age < @now_s and not Keyword.get(opts, :shared, false) ->
          "private, max-age=0, must-revalidate"

        age < @recent_s ->
          "private, max-age=30"

        true ->
          "private, max-age=86400"
      end

    conn =
      conn
      |> put_resp_header("cache-control", cache)
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
