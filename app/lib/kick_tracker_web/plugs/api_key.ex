defmodule KickTrackerWeb.Plugs.ApiKey do
  @moduledoc """
  The key a `/api/v1` request presents (project.md §13.10), in
  `Authorization: Bearer <key>` only (a key in the URL would end up in
  logs). `:fetch` assigns `api_key` (nil without a valid key) so the rate
  limit can count by key; `:require` then answers 401 without one.
  """

  @behaviour Plug

  import Plug.Conn

  alias KickTracker.ApiKeys
  alias KickTrackerWeb.Api.V1.JSON

  @impl true
  def init(mode) when mode in [:fetch, :require], do: mode

  @impl true
  def call(conn, :fetch) do
    key =
      with [header | _] <- get_req_header(conn, "authorization"),
           [scheme, raw] <- String.split(header, " ", parts: 2),
           true <- String.downcase(scheme) == "bearer",
           {:ok, key} <- ApiKeys.authenticate(String.trim(raw), conn.remote_ip) do
        ApiKeys.touch(key)
        key
      else
        _ -> nil
      end

    assign(conn, :api_key, key)
  end

  def call(%{assigns: %{api_key: %{}}} = conn, :require), do: conn

  def call(conn, :require) do
    conn
    |> JSON.error(
      401,
      "invalid_key",
      "A valid key is needed, in the header Authorization: Bearer <key>."
    )
    |> halt()
  end
end
