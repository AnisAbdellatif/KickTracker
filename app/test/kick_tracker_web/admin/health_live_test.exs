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

  test "a source that stopped reporting is stale, not ok" do
    channel = Fixtures.channel!()
    now = DateTime.utc_now()
    Coverage.mark([channel.id], "api", true, DateTime.add(now, -600), 150)
    assert [%{poll: %{state: :stale}, chat: %{state: :never}}] = Health.channels(now)
  end
end
