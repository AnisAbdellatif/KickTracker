defmodule KickTrackerWeb.ChartRefreshTest do
  @moduledoc """
  Charts left open keep up: a chart whose range ends now (a preset period,
  a live stream) asks its hook to fetch again every minute; a fixed range
  or an ended stream doesn't. The home page's sparklines move with each
  reading.
  """

  # Not async: writes hypertables.
  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures

  setup do
    KickTracker.Cache.clear()
    %{channel: channel!(slug: "somestreamer")}
  end

  defp refresh(html, id) do
    [tag] = Regex.run(~r/<div[^>]*id="#{id}"[^>]*>/, html)

    case Regex.run(~r/data-refresh="(\d+)"/, tag) do
      [_, s] -> String.to_integer(s)
      nil -> nil
    end
  end

  test "a rolling period's charts refresh; a fixed range's don't", %{conn: conn} do
    {:ok, _, html} = live(conn, "/c/somestreamer?period=7d")
    for id <- ~w(viewers-chart followers-chart heatmap-chart), do: assert(refresh(html, id) == 60)

    {:ok, _, html} = live(conn, "/c/somestreamer/chat")
    assert refresh(html, "chat-chart") == 60

    {:ok, _, html} = live(conn, "/c/somestreamer?from=1767225600&to=1767312000")
    assert refresh(html, "viewers-chart") == nil
  end

  test "the compare page follows the same rule", %{conn: conn} do
    channel!(slug: "otherstreamer")
    {:ok, _, html} = live(conn, "/compare?c=somestreamer,otherstreamer&period=24h")
    assert refresh(html, "compare-chart-viewers") == 60

    {:ok, _, html} =
      live(conn, "/compare?c=somestreamer,otherstreamer&from=1767225600&to=1767312000")

    refute html =~ "data-refresh"
  end

  test "a live stream's chart refreshes; an ended one's doesn't", %{conn: conn, channel: c} do
    now = DateTime.utc_now()
    live = stream!(c, DateTime.add(now, -3600))
    {:ok, _, html} = live(conn, "/c/somestreamer/streams/#{live}")
    assert refresh(html, "stream-chart") == 60

    ended = stream!(c, DateTime.add(now, -86_400), DateTime.add(now, -80_000))
    {:ok, _, html} = live(conn, "/c/somestreamer/streams/#{ended}")
    assert refresh(html, "stream-chart") == nil
  end

  test "the home page's sparklines take in each new reading", %{conn: conn, channel: c} do
    now = DateTime.utc_now()
    s = stream!(c, DateTime.add(now, -3600))
    samples!(c, s, for(m <- 60..20//-1, do: {DateTime.add(now, -m * 60), 10}))

    {:ok, view, _} = live(conn, "/")
    before = view |> element("#spark-#{c.id}") |> render()
    refute before =~ ~r/data-values="[^"]*\b50\b/

    # A reading arrives, and the minute's broadcast with it.
    samples!(c, s, [{DateTime.add(now, -30), 50}])
    KickTracker.Cache.clear()
    send(view.pid, {:live, %{at: now, viewers: %{c.id => 50}}})

    assert view |> element("#spark-#{c.id}") |> render() =~ ~r/data-values="[^"]*\b50\b/
  end
end
