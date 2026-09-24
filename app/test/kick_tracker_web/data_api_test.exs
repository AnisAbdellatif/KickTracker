defmodule KickTrackerWeb.DataApiTest do
  @moduledoc """
  The `/data/v1` JSON endpoints: what a hidden channel or a private
  support page never shows, and no series over 2 000 points (§13.4).
  """

  # Not async: writes hypertables.
  use KickTrackerWeb.ConnCase, async: false

  import KickTracker.Fixtures
  alias KickTracker.{Repo, Settings}
  alias KickTrackerWeb.Period

  @t0 ~U[2026-03-02 20:00:00Z]
  defp at(min), do: DateTime.add(@t0, min * 60)

  setup do
    c = channel!(slug: "somestreamer")
    s = stream!(c, at(0), at(60))
    samples!(c, s, for(m <- 1..59, do: {at(m), 100}))
    %{c: c, s: s}
  end

  defp hide!(c), do: Repo.query!("UPDATE channels SET public = false WHERE id = $1", [c.id])

  test "a hidden channel's data isn't served, stream chatters included", %{
    conn: conn,
    c: c,
    s: s
  } do
    for path <- ["/data/v1/streams/#{s}", "/data/v1/streams/#{s}/chatters?window=5"],
        do: assert(json_response(get(conn, path), 200))

    hide!(c)

    # Before, the chatters answered 200 for a hidden channel's stream.
    for path <- [
          "/data/v1/streams/#{s}",
          "/data/v1/streams/#{s}/chatters?window=5",
          "/data/v1/channels/somestreamer/viewers?period=7d"
        ],
        do: assert(json_response(get(conn, path), 404) == %{"error" => "not found"}, path)
  end

  test "support data follows the support page's setting", %{conn: conn, s: s} do
    assert %{"subs" => _} =
             json_response(get(conn, "/data/v1/channels/somestreamer/support"), 200)

    {:ok, false} = Settings.put("support_page_public", false)

    # Before, both still answered with the figures.
    assert json_response(get(conn, "/data/v1/channels/somestreamer/support"), 404)

    assert %{"support" => %{"t" => [], "subs" => [], "gifts" => [], "kicks" => []}} =
             json_response(get(conn, "/data/v1/streams/#{s}"), 200)
  end

  describe "point counts" do
    setup %{c: c} do
      now = DateTime.utc_now()
      since = DateTime.add(now, -19 * 365, :day)
      Repo.query!("UPDATE channels SET tracked_since = $2 WHERE id = $1", [c.id, since])

      # Follower readings every 15 minutes for 90 days: before, every one
      # was sent for a 90-day range (8 640 points).
      Repo.insert_all(
        "follower_samples",
        for(
          i <- 0..(90 * 96),
          do: %{channel_id: c.id, observed_at: DateTime.add(now, -i * 900), followers: i}
        )
      )

      %{now: now}
    end

    test "no endpoint sends more than 2 000 points, for any period", %{conn: conn, now: now} do
      to = DateTime.to_unix(now)

      queries =
        Enum.map(Period.presets(), &"period=#{&1}") ++
          [
            # The longest custom range: before, 7 301 daily points.
            "from=#{to - Period.max_span_s()}&to=#{to}",
            "from=#{to - 7 * 86_400}&to=#{to}",
            "from=#{to - 90 * 86_400}&to=#{to}"
          ]

      for q <- queries do
        for series <- ~w(viewers chat support followers) do
          body = json_response(get(conn, "/data/v1/channels/somestreamer/#{series}?#{q}"), 200)
          assert length(body["t"]) <= 2_000, "#{series}?#{q}: #{length(body["t"])} points"
        end

        for metric <- ~w(viewers chat followers) do
          body =
            json_response(get(conn, "/data/v1/compare?c=somestreamer&metric=#{metric}&#{q}"), 200)

          for s <- body["series"],
              do: assert(length(s["t"]) <= 2_000, "compare #{metric}?#{q}: #{length(s["t"])}")
        end
      end
    end
  end

  test "\"all\" without a channel starts when the earliest public channel's tracking began", %{
    c: c
  } do
    early = ~U[2025-05-01 10:00:00Z]
    hidden = channel!()
    hide!(hidden)
    Repo.query!("UPDATE channels SET tracked_since = $2 WHERE id = $1", [c.id, early])
    Repo.query!("UPDATE channels SET tracked_since = $2 WHERE id = $1", [hidden.id, at(-10 ** 6)])

    # Before: always the last 365 days on the home, compare and category pages.
    p = Period.parse(%{"period" => "all"})
    assert p.key == "all" and p.from == early
  end

  test "daily figures of a timezone off the whole hour say they are approximate", %{
    conn: conn,
    c: c
  } do
    q = "from=#{DateTime.to_unix(at(-300 * 1440))}&to=#{DateTime.to_unix(at(1440))}"

    body = json_response(get(conn, "/data/v1/channels/somestreamer/viewers?#{q}"), 200)
    assert body["res"] == "1d" and not Map.has_key?(body, "note")

    Repo.query!("UPDATE channels SET timezone = 'Asia/Kolkata' WHERE id = $1", [c.id])

    body = json_response(get(conn, "/data/v1/channels/somestreamer/viewers?#{q}"), 200)
    assert body["note"] =~ "UTC hours"

    heat = json_response(get(conn, "/data/v1/channels/somestreamer/heatmap?#{q}"), 200)
    assert heat["note"] =~ "UTC hours"
  end
end
