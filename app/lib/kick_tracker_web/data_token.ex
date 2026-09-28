defmodule KickTrackerWeb.DataToken do
  @moduledoc """
  Keeps `/data/v1` to our own pages (project.md §13.5). Every page carries
  a signed, short-lived token (`<meta name="data-token">`); the chart hook
  sends it with each request, and `Plugs.DataToken` refuses one without it.

  Not a secret: anyone can load a page and read it. It makes `/data/v1`
  useless to build on (a scraper has to load and parse a page, rate-limited
  like pages, every few hours), so outside use goes to `/api/v1` with a key.

  A page left open past the token's life asks its LiveView for a new one
  (`"data_token"`, answered by this module's `on_mount` hook).
  """

  import Phoenix.LiveView, only: [attach_hook: 4]

  @salt "data v1"
  @max_age_s 6 * 3600

  @doc "A token for a page."
  @spec sign() :: String.t()
  def sign, do: Phoenix.Token.sign(KickTrackerWeb.Endpoint, @salt, :page)

  @doc "Whether a token is ours and still valid."
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(token) when is_binary(token),
    do:
      match?(
        {:ok, :page},
        Phoenix.Token.verify(KickTrackerWeb.Endpoint, @salt, token, max_age: max_age_s())
      )

  def valid?(_), do: false

  defp max_age_s, do: Application.get_env(:kick_tracker, :data_token_max_age_s, @max_age_s)

  @doc "LiveView `on_mount`: answers a page's request for a fresh token."
  def on_mount(:default, _params, _session, socket),
    do: {:cont, attach_hook(socket, :data_token, :handle_event, &refresh/3)}

  defp refresh("data_token", _params, socket), do: {:halt, %{token: sign()}, socket}
  defp refresh(_event, _params, socket), do: {:cont, socket}
end
