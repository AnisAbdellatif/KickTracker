defmodule KickTrackerWeb.Api.V1.JSON do
  @moduledoc """
  Answers of the public read API (project.md §13.10, `API.md`): its own
  format, a documented contract, apart from `/data/v1` (which follows our
  charts). Errors are `{"error": {"code", "message"}}`; messages are for
  developers, in English, and the codes are what to match on.
  """

  import Plug.Conn

  @doc "A successful answer, with an ETag and a browser-only `Cache-Control`."
  @spec send(Plug.Conn.t(), term(), DateTime.t()) :: Plug.Conn.t()
  def send(conn, data, to), do: KickTrackerWeb.Data.JSON.send(conn, data, to)

  @spec error(Plug.Conn.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(%{error: %{code: code, message: message}}))
  end

  @doc "A channel or stream that doesn't exist, or that the key doesn't reach: the same answer."
  def not_found(conn),
    do: error(conn, 404, "not_found", "No such channel or stream for this key.")

  @doc "A kind of data the key's scopes don't include."
  def out_of_scope(conn, scope),
    do: error(conn, 403, "out_of_scope", "This key can't read \"#{scope}\" for this channel.")

  @doc "A timestamp on a record: ISO 8601, UTC (series use unix seconds)."
  def time(nil), do: nil
  def time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def time(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> time()
end
