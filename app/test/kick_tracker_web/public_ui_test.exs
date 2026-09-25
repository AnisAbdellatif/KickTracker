defmodule KickTrackerWeb.PublicUITest do
  @moduledoc """
  The public pages' behaviour around their data: odd query strings, the
  custom range, live updates of the home and stream pages, what may be
  shown about people, error pages and the document's head.
  """

  # Not async: writes hypertables.
  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures

  alias KickTracker.Repo
  alias KickTrackerWeb.PageParams

  setup do
    KickTracker.Cache.clear()
    %{channel: channel!(slug: "somestreamer")}
  end

  describe "malformed query params" do
    setup do
      Repo.query!(
        "INSERT INTO categories (id, name, first_seen_at, updated_at) VALUES (1234567, 'Some Game', now(), now())"
      )

      :ok
    end

    test "are ignored rather than failing the page", %{conn: conn} do
      for path <- [
            "/?period[a]=1",
            "/?group[a]=1",
            "/?metric[]=x",
            "/?from[]=1&to[x]=2",
            "/c/somestreamer?period[]=7d",
            "/c/somestreamer/streams?sort[]=a",
            "/c/somestreamer/streams?category[]=1",
            "/c/somestreamer/streams?dir[a]=b",
            "/compare?c[]=a",
            "/compare?c[a]=somestreamer&metric[]=chat",
            "/category/some-game?period[a]=1"
          ] do
        assert html_response(get(conn, path), 200), path
        assert {:ok, _view, _html} = live(conn, path), path
      end
    end

    test "only strings are kept" do
      assert PageParams.clean(%{"a" => "1", "b" => %{"x" => "1"}, "c" => ["1"]}) == %{"a" => "1"}
      assert PageParams.clean(nil) == %{}
    end
  end

  describe "the custom range" do
    test "is days from the first to the last, both included" do
      assert PageParams.custom_range("2026-03-01", "2026-03-02") ==
               {:ok,
                %{
                  "from" => "#{DateTime.to_unix(~U[2026-03-01 00:00:00Z])}",
                  "to" => "#{DateTime.to_unix(~U[2026-03-03 00:00:00Z])}"
                }}
    end

    test "is read in the channel's timezone" do
      # UTC+1 in March: the day starts an hour earlier in UTC.
      assert {:ok, %{"from" => from}} =
               PageParams.custom_range("2026-03-01", "2026-03-01", "Africa/Tunis")

      assert from == "#{DateTime.to_unix(~U[2026-02-28 23:00:00Z])}"

      period = %KickTrackerWeb.Period{
        from: ~U[2026-02-28 23:00:00Z],
        to: ~U[2026-03-02 23:00:00Z],
        key: "custom"
      }

      assert PageParams.dates(period, "Africa/Tunis") == {"2026-03-01", "2026-03-02"}
      assert PageParams.dates(period) == {"2026-02-28", "2026-03-02"}
    end

    test "refuses what isn't a range" do
      assert {:error, _} = PageParams.custom_range("2026-03-02", "2026-03-01")
      assert {:error, _} = PageParams.custom_range("nope", "2026-03-01")
      assert {:error, _} = PageParams.custom_range(nil, nil)
      assert {:error, _} = PageParams.custom_range("2999-01-01", "2999-01-02")
      assert {:error, _} = PageParams.custom_range("1990-01-01", "2026-01-01")
    end

    test "is picked in the period picker and lands in the URL", %{conn: conn} do
      {:ok, view, html} = live(conn, "/?metric=kicks")
      assert html =~ ~s(id="custom-range")

      view
      |> form("#custom-range", %{"from" => "2026-03-01", "to" => "2026-03-02"})
      |> render_submit()

      path = assert_patch(view)
      query = URI.decode_query(URI.parse(path).query)
      assert query["from"] == "#{DateTime.to_unix(~U[2026-03-01 00:00:00Z])}"
      assert query["metric"] == "kicks"
      refute Map.has_key?(query, "period")

      # The picker shows the range it came from.
      html = render(view)
      assert html =~ ~s(value="2026-03-01") and html =~ ~s(value="2026-03-02")
    end

    test "on a channel's page, in the channel's timezone", %{conn: conn, channel: c} do
      Repo.query!("UPDATE channels SET timezone = 'Africa/Tunis' WHERE id = $1", [c.id])
      {:ok, view, _} = live(conn, "/c/somestreamer/streams")

      view
      |> form("#custom-range", %{"from" => "2026-03-01", "to" => "2026-03-01"})
      |> render_submit()

      path = assert_patch(view)
      assert URI.parse(path).path == "/c/somestreamer/streams"

      assert URI.decode_query(URI.parse(path).query)["from"] ==
               "#{DateTime.to_unix(~U[2026-02-28 23:00:00Z])}"
    end

    test "a bad range is refused with a message", %{conn: conn} do
      {:ok, view, _} = live(conn, "/compare")

      html =
        view
        |> form("#custom-range", %{"from" => "2026-03-02", "to" => "2026-03-01"})
        |> render_submit()

      assert html =~ "The range has to start before it ends."
    end
  end

  describe "the home page" do
    test "names gifters only while top people are public", %{conn: conn, channel: c} do
      now = DateTime.utc_now()

      Repo.query!(
        "INSERT INTO kick_users (id, username, seen_at) VALUES (7654321, 'somegifter', now())"
      )

      Repo.query!(
        "INSERT INTO support_events (message_id, channel_id, occurred_at, kind, user_id, quantity) VALUES ('m1', $1, $2, 'gift', 7654321, 50)",
        [c.id, DateTime.add(now, -3600)]
      )

      {:ok, _, html} = live(conn, "/")
      assert html =~ "somegifter"

      {:ok, false} = KickTracker.Settings.put("top_people_public", false)
      KickTracker.Cache.clear()
      {:ok, _, html} = live(conn, "/")
      assert html =~ "subs gifted at once"
      refute html =~ "somegifter"
    end

    test "sparklines come from cacheable JSON, and move with each minute", %{
      conn: conn,
      channel: c
    } do
      now = DateTime.utc_now()
      s = stream!(c, DateTime.add(now, -3600))
      samples!(c, s, for(m <- 60..20//-1, do: {DateTime.add(now, -m * 60), 10}))

      {:ok, view, _} = live(conn, "/")
      card = view |> element("#spark-#{c.id}") |> render()
      refute card =~ "data-values"
      [_, src] = Regex.run(~r/data-src="([^"]+)"/, card)
      assert src =~ "/data/v1/sparklines/somestreamer?at="

      next = DateTime.add(now, 120)
      send(view.pid, {:live, %{at: next, viewers: %{c.id => 50}}})
      card = view |> element("#spark-#{c.id}") |> render()
      assert card =~ "at=#{div(DateTime.to_unix(next), 60) * 60}"

      body = json_response(get(conn, String.replace(src, "&amp;", "&")), 200)
      assert Enum.any?(body["values"], &(&1 == 10))
      assert get_resp_header(get(conn, src), "cache-control") == ["public, max-age=30"]

      # Private channels have no sparkline.
      channel!(slug: "hiddenstreamer") |> Ecto.Changeset.change(public: false) |> Repo.update!()
      assert json_response(get(conn, "/data/v1/sparklines/hiddenstreamer"), 404)
    end

    test "a broadcast naming private channels doesn't read the list again", %{
      conn: conn,
      channel: c
    } do
      now = DateTime.utc_now()
      stream!(c, DateTime.add(now, -3600))

      hidden =
        channel!(slug: "hiddenstreamer") |> Ecto.Changeset.change(public: false) |> Repo.update!()

      {:ok, view, _} = live(conn, "/")
      assert has_element?(view, "#live-#{c.id}")

      # Another channel's stream opens here, but the broadcast doesn't
      # name it yet: the list is not read again for the private one.
      other = channel!(slug: "otherstreamer")
      stream!(other, DateTime.add(now, -60))
      send(view.pid, {:live, %{at: now, viewers: %{c.id => 42, hidden.id => 9}}})
      refute has_element?(view, "#live-#{other.id}")
      assert view |> element("#live-#{c.id}") |> render() =~ "42"

      # Once it is named, it is.
      send(view.pid, {:live, %{at: now, viewers: %{c.id => 42, other.id => 5, hidden.id => 9}}})
      assert has_element?(view, "#live-#{other.id}")
    end
  end

  describe "the stream page" do
    setup %{channel: c} do
      now = DateTime.utc_now()
      started = DateTime.add(now, -3600)
      id = stream!(c, started)
      samples!(c, id, [{DateTime.add(now, -120), 10}])
      %{stream_id: id, started: started, now: now}
    end

    test "appends readings while live and stops once the stream ended", ctx do
      %{conn: conn, channel: c, stream_id: id, now: now} = ctx
      {:ok, view, _} = live(conn, "/c/somestreamer/streams/#{id}")

      send(view.pid, {:viewers, %{at: now, viewers: 25, category_id: nil}})
      assert_push_event(view, "chart:append", %{id: "stream-chart", values: %{avg: 25}})

      ended = DateTime.add(now, 30)

      Repo.query!("UPDATE streams SET ended_at = $2, end_source = 'event' WHERE id = $1", [
        id,
        ended
      ])

      send(view.pid, {:stream_ended, ctx.started, ended})
      assert render(view) =~ "ended"

      # A new stream's reading on the same channel isn't this stream's.
      send(view.pid, {:viewers, %{at: DateTime.add(now, 600), viewers: 999, category_id: nil}})
      render(view)
      refute_push_event(view, "chart:append", %{values: %{avg: 999}})

      # And it no longer listens at all.
      Phoenix.PubSub.broadcast(
        KickTracker.PubSub,
        KickTracker.Tracking.ChannelServer.topic(c.id),
        {:viewers, %{at: DateTime.add(now, 660), viewers: 998, category_id: nil}}
      )

      render(view)
      refute_push_event(view, "chart:append", %{values: %{avg: 998}})
    end

    test "a new stream starting closes this one's live view", ctx do
      %{conn: conn, stream_id: id, now: now} = ctx
      {:ok, view, _} = live(conn, "/c/somestreamer/streams/#{id}")

      Repo.query!("UPDATE streams SET ended_at = $2, end_source = 'poll' WHERE id = $1", [id, now])

      send(view.pid, {:stream_started, DateTime.add(now, 60)})
      render(view)
      send(view.pid, {:viewers, %{at: DateTime.add(now, 120), viewers: 777, category_id: nil}})
      render(view)
      refute_push_event(view, "chart:append", %{values: %{avg: 777}})
    end

    test "the cards follow the stream while live, at most once a minute", ctx do
      %{conn: conn, channel: c, stream_id: id, now: now} = ctx
      {:ok, view, _} = live(conn, "/c/somestreamer/streams/#{id}")
      refute has_element?(view, "#stream-cards")

      Repo.query!(
        """
        INSERT INTO stream_stats (stream_id, channel_id, computed_at, airtime_s, samples, avg_viewers,
          peak_viewers, hours_watched, follows, unique_chatters, messages, subs, resubs, gifted_subs, kicks)
        VALUES ($1, $2, now(), 3600, 60, 20.0, 4321, 20.0, 0, 3, 10, 0, 0, 0, 0)
        """,
        [id, c.id]
      )

      # Within the minute: not read again yet.
      send(view.pid, {:viewers, %{at: DateTime.add(now, 10), viewers: 30, category_id: nil}})
      refute has_element?(view, "#stream-cards")

      send(view.pid, {:viewers, %{at: DateTime.add(now, 70), viewers: 30, category_id: nil}})
      assert view |> element("#stream-cards") |> render() =~ "4321"
    end

    test "the tz switch keeps its own state, and chart labels are translated", ctx do
      {:ok, _view, html} = live(ctx.conn, "/c/somestreamer/streams/#{ctx.stream_id}")
      assert html =~ ~r/id="tz-switch"[^>]*phx-update="ignore"/
      assert html =~ "5 min"
      [_, opts] = Regex.run(~r/id="stream-chart"[^>]*data-opts="([^"]+)"/, html)
      opts = opts |> String.replace("&quot;", "\"") |> Jason.decode!()
      assert opts["labels"]["kinds"]["raid_in"] == "Raid in"
      assert opts["labels"]["kicks"] == "Kicks"
    end
  end

  describe "the document" do
    test "has its language, direction, description and link preview", %{conn: conn} do
      html = html_response(get(conn, "/c/somestreamer"), 200)
      assert html =~ ~r/<html[^>]* lang="en" dir="ltr">/
      assert html =~ ~r/<meta name="description" content="[^"]*somestreamer/
      assert html =~ ~s(<meta property="og:site_name" content="Stream Tracker">)
      assert html =~ ~s(<meta property="og:title" content="somestreamer">)
      assert html =~ ~r/property="og:url" content="http[^"]*\/c\/somestreamer"/
    end

    test "the theme buttons are named, and the chart error text is translatable", %{conn: conn} do
      html = html_response(get(conn, "/c/somestreamer"), 200)

      for name <- ["System theme", "Light theme", "Dark theme"],
          do: assert(html =~ ~s(aria-label="#{name}"))

      assert html =~ ~s(data-error="Couldn&#39;t load this chart.")
      refute html =~ ~r/class="[^"]*\b(ml|mr|pl|pr)-\d/
    end

    test "errors are pages of the site, with a way home", %{conn: conn} do
      {404, _, body} = assert_error_sent(404, fn -> get(conn, "/c/nosuchstreamer") end)
      assert body =~ "Page not found"
      assert body =~ ~s(href="/")
      assert body =~ ~r/<html[^>]* lang="en" dir="ltr">/
    end
  end

  test "the compare page's tables scroll on a phone rather than the page", %{conn: conn} do
    channel!(slug: "otherstreamer")
    {:ok, _, html} = live(conn, "/compare?c=somestreamer,otherstreamer")
    assert html =~ ~r/<div class="[^"]*overflow-x-auto[^"]*">\s*<table id="overlap"/
    assert html =~ ~r/<div class="[^"]*overflow-x-auto[^"]*">\s*<table id="compare-table"/
  end

  test "a channel's overview colours each figure by its metric and shows its weekdays", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/c/somestreamer")
    assert has_element?(view, "#kpis .stat-card.m-hw")
    assert has_element?(view, "#kpis .stat-card.m-followers")
    # A channel with no readings: seven weekdays, every figure unknown or no airtime.
    assert has_element?(view, "#weekdays .m-avg")
    html = view |> element("#weekdays") |> render()
    assert length(Regex.scan(~r/Mon|Tue|Wed|Thu|Fri|Sat|Sun/, html)) == 21
    refute html =~ "style=\"width"
  end
end
