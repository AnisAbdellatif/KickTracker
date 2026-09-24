defmodule KickTrackerWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  A Content-Security-Policy on every page (project.md §19.3): scripts only
  from our own origin, plus inline scripts carrying this request's nonce
  (the theme script in the root layout; LiveDashboard and ErrorTracker
  read it from `conn.assigns.csp_nonce`). Styles may be inline (Tailwind
  and the charts set style attributes); nothing may frame the site.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    policy =
      Enum.join(
        [
          "default-src 'self'",
          "script-src 'self' 'nonce-#{nonce}'",
          "style-src 'self' 'unsafe-inline'",
          "img-src 'self' data: blob:",
          "font-src 'self' data:",
          "connect-src 'self'",
          "object-src 'none'",
          "base-uri 'self'",
          "form-action 'self'",
          "frame-ancestors 'self'"
        ],
        "; "
      )

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy)
  end
end
