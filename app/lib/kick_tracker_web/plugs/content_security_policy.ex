defmodule KickTrackerWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  A Content-Security-Policy on every page (project.md §19.3): scripts only
  from our own origin, plus inline scripts carrying this request's nonce
  (the theme script in the root layout; LiveDashboard and ErrorTracker
  read it from `conn.assigns.csp_nonce`). Styles may be inline (Tailwind
  and the charts set style attributes); nothing may frame the site.

  Images come from our own origin, except on admin pages, which may also
  load Kick's (the chat log's emotes, `KICK_FILES_URL`): a public visitor's
  browser never contacts Kick.
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
          "img-src 'self' data: blob:" <> kick_images(conn),
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

  defp kick_images(%Plug.Conn{path_info: ["admin" | _]}) do
    case URI.parse(KickTracker.ChatLog.files_url()) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) ->
        " #{scheme}://#{host}#{if port in [80, 443], do: "", else: ":#{port}"}"

      _ ->
        ""
    end
  end

  defp kick_images(_conn), do: ""
end
