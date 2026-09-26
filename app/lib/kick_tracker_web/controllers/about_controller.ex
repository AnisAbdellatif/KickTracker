defmodule KickTrackerWeb.AboutController do
  @moduledoc "Static pages: methodology (project.md §13.2), privacy and removal requests (§18.3), and channel search."

  use KickTrackerWeb, :controller

  def methodology(conn, _params),
    do: render(conn, :methodology, page_title: gettext("Methodology"))

  # What the page says is shown about people follows the settings that
  # show it (top chatters and supporters; the support page).
  def privacy(conn, _params) do
    render(conn, :privacy,
      page_title: gettext("Privacy"),
      chat_log: KickTracker.ChatLog.disclosed(),
      top_people: KickTracker.Settings.get("top_people_public"),
      support_page: KickTracker.Settings.get("support_page_public")
    )
  end

  def removal(conn, _params), do: render(conn, :removal, page_title: gettext("Removal requests"))

  def search(conn, %{"q" => q}) when is_binary(q) and q != "" do
    case KickTracker.Reports.search(q) do
      [one] -> redirect(conn, to: ~p"/c/#{one.slug}")
      results -> render(conn, :search, q: q, results: results, page_title: gettext("Search"))
    end
  end

  def search(conn, _params),
    do: render(conn, :search, q: "", results: [], page_title: gettext("Search"))
end
