defmodule KickTrackerWeb.Admin.HealthLiveTest do
  use KickTrackerWeb.ConnCase

  import Phoenix.LiveViewTest
  alias KickTracker.{Fixtures, Health}
  alias KickTracker.Stats.Coverage

  setup :log_in_admin

  test "shows each channel's sources and coverage", %{conn: conn} do
    channel = Fixtures.channel!(slug: "somestreamer")
    now = DateTime.utc_now()
    # Polled fine for the last 30 minutes; chat failed a minute ago.
    for m <- 30..1//-1,
        do: Coverage.mark([channel.id], "api", true, DateTime.add(now, -m * 60), 150)

    Coverage.mark([channel.id], "chat", false, DateTime.add(now, -60), 150)

    [row] = Health.channels(now)
    assert row.poll.state == :ok
    assert row.chat.state == :failing
    assert_in_delta row.coverage.api_24h, 30 * 60 / 86_400, 0.001
    assert row.coverage.chat_24h == 0.0

    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "somestreamer"
    assert html =~ "failing"
  end

  test "open alerts are listed first", %{conn: conn} do
    KickTracker.Repo.insert_all("alerts", [
      %{
        key: "dead_letters",
        message: "2 message(s) in the dead-letter queue",
        first_at: DateTime.utc_now(),
        last_at: DateTime.utc_now()
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Open alerts" and html =~ "dead-letter queue"
  end

  test "/healthz answers while the database does", %{conn: conn} do
    assert response(get(conn, "/healthz"), 200) == "ok"
  end

  test "a source that stopped reporting is stale, not ok" do
    channel = Fixtures.channel!()
    now = DateTime.utc_now()
    Coverage.mark([channel.id], "api", true, DateTime.add(now, -600), 150)
    assert [%{poll: %{state: :stale}, chat: %{state: :never}}] = Health.channels(now)
  end
end
