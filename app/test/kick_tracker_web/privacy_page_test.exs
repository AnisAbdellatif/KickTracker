defmodule KickTrackerWeb.PrivacyPageTest do
  @moduledoc "The privacy page says what the site actually does (§18.3)."

  use KickTrackerWeb.ConnCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{ChatLog, Settings}

  test "lists the channels chat is logged on, with their retention; hidden ones only counted",
       %{conn: conn} do
    html = html_response(get(conn, ~p"/about/privacy"), 200)
    assert html =~ "not turned on for any channel"

    shown = channel!(slug: "somestreamer")
    hidden = channel!(slug: "otherstreamer")
    _not_logged = channel!(slug: "quietstreamer")
    {:ok, _} = ChatLog.configure(shown, true, 30)
    {:ok, hidden} = ChatLog.configure(hidden, true, 90)
    {:ok, _} = KickTracker.Channels.set_public(hidden, false)

    html = html_response(get(conn, ~p"/about/privacy"), 200)
    assert html =~ "somestreamer"
    assert html =~ "kept 30 days"
    refute html =~ "otherstreamer"
    refute html =~ "quietstreamer"
    assert html =~ "and 1 channel not listed on this site"
  end

  test "what it says is shown about people follows the settings", %{conn: conn} do
    shown = fn -> html_response(get(conn, ~p"/about/privacy"), 200) end

    assert shown.() =~ "top chatters and supporters, and a channel&#39;s top supporters"

    Settings.put("top_people_public", false)
    assert shown.() =~ "a channel&#39;s top supporters, by Kick username"

    Settings.put("support_page_public", false)
    assert shown.() =~ "Nothing that identifies a person"
  end
end
