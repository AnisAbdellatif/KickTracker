defmodule KickTrackerWeb.UnknownFiguresTest do
  @moduledoc """
  Every page and data endpoint renders when every figure that may be
  unknown is unknown.

  Gaps are gaps (AGENTS.md §7): a column that can be NULL will be NULL for
  some rows in production (history from before a source was recorded, a
  webhook outage, a stream with no readings), and code that adds, rounds
  or compares it without handling `nil` crashes the page. Rather than list
  the columns, this reads every nullable column of the collected and
  derived tables from the schema, sets them all to NULL, and walks the
  site: a column made nullable later is covered without touching this
  test.
  """

  # Not async: writes hypertables.
  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias KickTracker.{Bulk, Repo, Reports}

  @to ~U[2026-03-05 00:00:00Z]

  # The tables whose nullable columns hold collected or derived figures.
  @tables ~w(channels streams stream_stats hourly_stats viewer_samples follower_samples
             chat_minutes chat_minute_users support_events follows stream_changes kick_users
             categories)

  # Nullable columns whose NULL is a state, not an unknown figure; each
  # has its own tests. Say why when adding one.
  @not_figures %{
    # NULL means the stream is still open; every open stream is live.
    {"streams", "ended_at"} => :state,
    # NULL exactly when ended_at is (check constraint end_source_with_end).
    {"streams", "end_source"} => :state
  }

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

  # sobelow_skip ["SQL.Query"]
  defp null_every_unknown_figure! do
    columns =
      Repo.query!(
        """
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND is_nullable = 'YES' AND table_name = ANY($1)
        ORDER BY 1, 2
        """,
        [@tables]
      ).rows
      |> Enum.map(&List.to_tuple/1)
      |> Enum.reject(&Map.has_key?(@not_figures, &1))

    for {table, column} <- columns do
      Repo.query!(~s(UPDATE "#{table}" SET "#{column}" = NULL))
    end

    columns
  end

  test "the webhook counts and other figures that can be unknown are among those nulled" do
    nulled = null_every_unknown_figure!()

    # The columns that caused crashes before: a guard against the list
    # silently shrinking (a table renamed, a column made NOT NULL again).
    for c <- ~w(subs resubs gifted_subs kicks follows follower_gain avg_viewers peak_viewers) do
      assert {"stream_stats", c} in nulled, c
    end
  end

  test "every public page and data endpoint renders with every unknown figure unknown", %{
    conn: conn
  } do
    [stream | _] = Reports.streams(Reports.channel_by_slug("dailystreamer"))
    null_every_unknown_figure!()

    live_pages = [
      "/",
      "/?metric=peak_viewers&period=7d",
      "/?metric=follower_gain&period=all",
      "/?metric=kicks",
      "/?metric=avg_viewers",
      "/c/dailystreamer?#{@range}",
      "/c/dailystreamer?period=all",
      "/c/dailystreamer/streams?#{@range}",
      "/c/dailystreamer/streams?sort=peak_viewers&#{@range}",
      "/c/dailystreamer/streams?sort=follower_gain&dir=asc&#{@range}",
      "/c/dailystreamer/chat?#{@range}",
      "/c/dailystreamer/support?#{@range}",
      "/c/dailystreamer/categories?#{@range}",
      "/c/dailystreamer/streams/#{stream.id}",
      "/compare?c=dailystreamer,otherstreamer&#{@range}",
      "/category/just-chatting?#{@range}"
    ]

    for path <- live_pages do
      assert {:ok, _view, _html} = live(conn, path), path
    end

    json =
      for(
        s <- ~w(viewers chat support followers heatmap categories),
        do: "/data/v1/channels/dailystreamer/#{s}?#{@range}"
      ) ++
        [
          "/data/v1/streams/#{stream.id}",
          "/data/v1/streams/#{stream.id}/chatters?window=5",
          "/data/v1/compare?c=dailystreamer,otherstreamer&#{@range}",
          "/data/v1/sparklines/dailystreamer"
        ]

    for path <- json do
      assert json_response(get(conn, path), 200), path
    end

    for path <- ["/about/methodology", "/search?q=streamer"] do
      assert html_response(get(conn, path), 200), path
    end
  end

  describe "admin" do
    setup :log_in_admin

    test "every admin page renders with every unknown figure unknown", %{conn: conn} do
      null_every_unknown_figure!()

      for path <-
            ~w(/admin /admin/channels /admin/groups /admin/data /admin/privacy /admin/settings /admin/audit /admin/transfer) do
        assert {:ok, _view, _html} = live(conn, path), path
      end
    end
  end
end
