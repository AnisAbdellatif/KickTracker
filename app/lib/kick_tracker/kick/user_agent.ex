defmodule KickTracker.Kick.UserAgent do
  @moduledoc """
  The User-Agent on every request to Kick (project.md §18.3): who we are
  and how to reach us, e.g. `Stream Tracker/0.1 (+https://example.org;
  contact@example.org)`. From `KICK_USER_AGENT`, or built from the site
  name, `PHX_HOST` and `CONTACT_EMAIL`.
  """

  @doc "The header value."
  @spec value() :: String.t()
  def value do
    Application.get_env(:kick_tracker, :kick_user_agent) || build()
  end

  @doc "As a header list, for Req and Mint."
  @spec headers() :: [{String.t(), String.t()}]
  def headers, do: [{"user-agent", value()}]

  defp build do
    name = KickTrackerWeb.Layouts.site_name() |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    version = Application.spec(:kick_tracker, :vsn) || "0"
    host = get_in(Application.get_env(:kick_tracker, KickTrackerWeb.Endpoint, []), [:url, :host])
    contact = Application.get_env(:kick_tracker, :contact_email)
    details = Enum.reject([host && "+https://#{host}", contact], &is_nil/1)
    "#{name}/#{version}" <> if(details == [], do: "", else: " (#{Enum.join(details, "; ")})")
  end
end
