defmodule KickTrackerWeb.ChannelVisibilityTest do
  @moduledoc """
  The two levels of hiding (project.md §13.2): a live-only channel shows
  only "now" while live (viewers, active chatters), a hidden one nothing.
  """

  # Not async: writes hypertables.
  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures

  alias KickTracker.{Repo, Series}

  setup do
    KickTracker.Cache.clear()
    now = DateTime.utc_now()

    public = channel!(slug: "somestreamer")
    live_only = channel!(slug: "liveonlystreamer", visibility: :live_only)
    hidden = channel!(slug: "hiddenstreamer", visibility: :hidden)

    streams =
      for c <- [public, live_only, hidden], into: %{} do
        started = DateTime.add(now, -3600)
        s = stream!(c, started)
        samples!(c, s, [{DateTime.add(now, -60), 120}], nil)

        Repo.query!(
          "INSERT INTO stream_changes (stream_id, field, new_value, occurred_at, source) VALUES ($1, 'title', 'Some title', $2, 'poll')",
          [s, started]
        )

        {c.slug, s}
      end

    %{public: public, live_only: live_only, hidden: hidden, streams: streams, now: now}
  end

  test "the home page lists a live-only channel with its viewers alone", %{
    conn: conn,
    live_only: lo,
    hidden: hidden
  } do
    {:ok, view, _} = live(conn, "/")
    card = view |> element("#live-#{lo.id}") |> render()

    assert card =~ "liveonlystreamer"
    assert card =~ "120"
    assert card =~ ~s(href="/c/liveonlystreamer")
    refute card =~ "Some title"
    refute card =~ "live for"
    refute card =~ "sparkline"
    refute has_element?(view, "#live-#{hidden.id}")
  end

  test "a live-only channel's page has now and nothing else", %{
    conn: conn,
    live_only: lo,
    streams: streams
  } do
    {:ok, view, html} = live(conn, "/c/liveonlystreamer")
    assert html =~ "Only live figures are published"
    assert has_element?(view, "#live-only-now")
    refute html =~ "Tracked since"
    refute html =~ "/data/v1"

    # No chat coverage: active chatters are unknown, not 0.
    assert view |> element("#live-only-now") |> render() =~ "–"

    for path <-
          ~w(/c/liveonlystreamer/streams /c/liveonlystreamer/chat /c/liveonlystreamer/categories) do
      assert_raise KickTrackerWeb.NotFoundError, fn -> live(conn, path) end
    end

    assert_raise KickTrackerWeb.NotFoundError, fn ->
      live(conn, "/c/liveonlystreamer/streams/#{streams["liveonlystreamer"]}")
    end

    for path <- [
          "/data/v1/channels/liveonlystreamer/viewers",
          "/data/v1/streams/#{streams["liveonlystreamer"]}",
          "/data/v1/sparklines/liveonlystreamer"
        ] do
      assert json_response(get(conn, path), 404), path
    end

    # Offline, the page says so.
    Repo.query!(
      "UPDATE streams SET ended_at = now(), end_source = 'event' WHERE channel_id = $1",
      [lo.id]
    )

    {:ok, _view, html} = live(conn, "/c/liveonlystreamer")
    assert html =~ "Not live right now"
  end

  test "a live-only channel's viewers and active chatters follow the broadcast", %{
    conn: conn,
    live_only: lo,
    now: now
  } do
    minute = DateTime.from_unix!(div(DateTime.to_unix(now), 60) * 60)
    covered!(lo, "chat", DateTime.add(now, -3600), DateTime.add(now, 60))

    Repo.insert_all(
      "chat_minute_users",
      for {m, u} <- [{-2, 1}, {-2, 2}, {-1, 2}, {-1, 3}, {-9, 4}] do
        %{channel_id: lo.id, minute: DateTime.add(minute, m * 60), user_id: u, messages: 1}
      end
    )

    {:ok, view, _} = live(conn, "/c/liveonlystreamer")
    assert view |> element("#live-only-now") |> render() =~ ~r/>\s*3\s*</

    send(view.pid, {:viewers, %{viewers: 345, at: now}})
    assert view |> element("#live-only-now") |> render() =~ "345"
  end

  test "a hidden channel is nowhere on the public site", %{conn: conn, streams: streams} do
    assert_raise KickTrackerWeb.NotFoundError, fn -> live(conn, "/c/hiddenstreamer") end
    assert json_response(get(conn, "/data/v1/channels/hiddenstreamer/viewers"), 404)
    assert json_response(get(conn, "/data/v1/streams/#{streams["hiddenstreamer"]}"), 404)
    refute html_response(get(conn, "/search?q=streamer"), 200) =~ "hiddenstreamer"
  end

  test "search finds live-only channels, leaderboards don't list them", %{conn: conn} do
    html = html_response(get(conn, "/search?q=streamer"), 200)
    assert html =~ "liveonlystreamer"

    board =
      KickTracker.Reports.leaderboard(
        DateTime.add(DateTime.utc_now(), -86_400),
        DateTime.utc_now(),
        "hours_watched"
      )

    assert Enum.map(board, & &1.slug) |> Enum.sort() == ["somestreamer"]
  end

  describe "Series.chatters_now/3" do
    test "counts distinct chatters in the last whole minutes, unknown without coverage", %{
      live_only: c,
      now: now
    } do
      minute = DateTime.from_unix!(div(DateTime.to_unix(now), 60) * 60)

      Repo.insert_all(
        "chat_minute_users",
        for {m, u} <- [{-1, 1}, {-1, 2}, {-5, 2}, {-6, 9}, {0, 7}] do
          %{channel_id: c.id, minute: DateTime.add(minute, m * 60), user_id: u, messages: 1}
        end
      )

      assert Series.chatters_now(c.id, 5, now) == nil

      covered!(c, "chat", DateTime.add(now, -3600), DateTime.add(now, 60))
      # Minutes -5..-1: users 1 and 2 (the current minute isn't whole yet).
      assert Series.chatters_now(c.id, 5, now) == 2
      assert Series.chatters_now(c.id, 6, now) == 3
    end
  end
end
