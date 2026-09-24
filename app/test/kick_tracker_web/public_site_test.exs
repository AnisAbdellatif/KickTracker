defmodule KickTrackerWeb.PublicSiteTest do
  @moduledoc "Every public page and data endpoint, on a few days of bulk-mode history."

  # Not async: writes hypertables.
  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias KickTracker.{Bulk, Reports}

  @to ~U[2026-03-05 00:00:00Z]

  setup do
    scenario =
      Sim.Scenario.new(
        seed: 3,
        channels: [
          [
            slug: "dailystreamer",
            peak_viewers: 300,
            schedule: %{days: [1, 2, 3, 4, 5, 6, 7], start_hour: 20, duration_min: 120}
          ],
          [
            slug: "otherstreamer",
            peak_viewers: 80,
            schedule: %{days: [1, 2, 3, 4, 5, 6, 7], start_hour: 18, duration_min: 90}
          ]
        ]
      )

    Bulk.run(scenario, DateTime.add(@to, -3, :day), @to)
    :ok
  end

  @range "from=#{DateTime.to_unix(DateTime.add(@to, -3, :day))}&to=#{DateTime.to_unix(@to)}"

  test "every public page renders", %{conn: conn} do
    [stream | _] = Reports.streams(Reports.channel_by_slug("dailystreamer"))

    for path <- [
          "/",
          "/?metric=peak_viewers&period=7d",
          "/c/dailystreamer?#{@range}",
          "/c/dailystreamer/streams?sort=peak_viewers&dir=asc&#{@range}",
          "/c/dailystreamer/chat?#{@range}",
          "/c/dailystreamer/support?#{@range}",
          "/c/dailystreamer/categories?#{@range}",
          "/c/dailystreamer/streams/#{stream.id}",
          "/compare?c=dailystreamer,otherstreamer&#{@range}",
          "/compare",
          "/category/just-chatting?#{@range}"
        ] do
      assert {:ok, _view, html} = live(conn, path), path
      assert html =~ "Stream Tracker"
    end

    for path <- ["/about/methodology", "/about/privacy", "/about/removal", "/search?q=nothing"] do
      assert html_response(get(conn, path), 200)
    end

    assert redirected_to(get(conn, "/search?q=dailystr")) == "/c/dailystreamer"
  end

  test "the support page is public only while the setting says so", %{conn: conn} do
    assert {:ok, _, _} = live(conn, "/c/dailystreamer/support")
    {:ok, false} = KickTracker.Settings.put("support_page_public", false)
    assert_error_sent 404, fn -> get(conn, "/c/dailystreamer/support") end
    {:ok, _, html} = live(conn, "/c/dailystreamer")
    refute html =~ "/c/dailystreamer/support"
  end

  test "unknown channels, streams and categories are 404s", %{conn: conn} do
    for path <- [
          "/c/nosuchstreamer",
          "/c/dailystreamer/streams/999999999",
          "/category/nothing-here"
        ] do
      assert_error_sent 404, fn -> get(conn, path) end
    end

    assert json_response(get(conn, "/data/v1/channels/nosuchstreamer/viewers"), 404)
    assert json_response(get(conn, "/data/v1/channels/dailystreamer/nonsense"), 404)
    assert json_response(get(conn, "/data/v1/streams/abc"), 404)
  end

  test "the stream page shows the stream's stats and changes", %{conn: conn} do
    [stream | _] = Reports.streams(Reports.channel_by_slug("dailystreamer"))
    {:ok, view, _} = live(conn, "/c/dailystreamer/streams/#{stream.id}")
    assert has_element?(view, "#stream-cards")
    assert has_element?(view, "#timeline li")
    assert has_element?(view, "#stream-chart[data-kind=stream]")
    # Time charts can be zoomed back out to all their data.
    assert has_element?(view, "figure:has(#stream-chart) [data-chart-action=fit]")
  end

  test "channel series come in columns, with the resolution chosen by range", %{conn: conn} do
    v = json_response(get(conn, "/data/v1/channels/dailystreamer/viewers?#{@range}"), 200)
    assert v["res"] == "5m"
    assert length(v["t"]) == length(v["avg"]) and length(v["t"]) == length(v["max"])
    assert length(v["t"]) <= 2000
    assert nil in v["avg"] and Enum.any?(v["avg"], &is_integer/1)

    # A coarser resolution can be asked for, a finer one can't.
    assert json_response(
             get(conn, "/data/v1/channels/dailystreamer/viewers?res=1h&#{@range}"),
             200
           )["res"] == "1h"

    assert json_response(
             get(conn, "/data/v1/channels/dailystreamer/viewers?res=raw&#{@range}"),
             200
           )["res"] == "5m"

    for s <- ~w(chat support followers heatmap categories) do
      assert %{} = json_response(get(conn, "/data/v1/channels/dailystreamer/#{s}?#{@range}"), 200)
    end

    [stream | _] = Reports.streams(Reports.channel_by_slug("dailystreamer"))
    d = json_response(get(conn, "/data/v1/streams/#{stream.id}"), 200)
    assert d["viewers"]["res"] == "raw" and d["segments"] != []

    assert %{"window" => 10} =
             json_response(get(conn, "/data/v1/streams/#{stream.id}/chatters?window=10"), 200)

    c =
      json_response(
        get(conn, "/data/v1/compare?c=dailystreamer,otherstreamer&metric=chat&#{@range}"),
        200
      )

    assert Enum.map(c["series"], & &1["name"]) == ["dailystreamer", "otherstreamer"]
  end

  test "closed ranges are cached long, and a repeat with its ETag is a 304", %{conn: conn} do
    conn1 = get(conn, "/data/v1/channels/dailystreamer/viewers?#{@range}")
    assert get_resp_header(conn1, "cache-control") == ["public, max-age=86400"]
    [etag] = get_resp_header(conn1, "etag")

    conn2 =
      conn
      |> put_req_header("if-none-match", etag)
      |> get("/data/v1/channels/dailystreamer/viewers?#{@range}")

    assert conn2.status == 304

    # A range reaching now is cached briefly.
    conn3 = get(conn, "/data/v1/channels/dailystreamer/viewers?period=7d")
    assert get_resp_header(conn3, "cache-control") == ["public, max-age=30"]
  end

  test "the home page updates live from the aggregated broadcast", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    channel = Reports.channel_by_slug("dailystreamer")
    send(view.pid, {:live, %{at: DateTime.utc_now(), viewers: %{channel.id => 123}}})
    # Nobody is live in this data: a broadcast naming a channel re-reads the list.
    assert render(view) =~ "Live now"
  end
end
