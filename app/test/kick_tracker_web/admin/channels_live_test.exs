defmodule KickTrackerWeb.Admin.ChannelsLiveTest do
  use KickTracker.SimCase
  @moduletag :capture_log

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import KickTrackerWeb.ConnCase, only: [log_in_admin: 2]

  alias KickTracker.{Audit, Channels, Fixtures}

  @endpoint KickTrackerWeb.Endpoint

  setup do
    start_sim([
      [slug: "livestreamer", schedule: :always, peak_viewers: 500],
      [slug: "offlinestreamer", schedule: :never]
    ])

    start_supervised!(KickTracker.Kick.Token)
    Phoenix.PubSub.subscribe(KickTracker.PubSub, Channels.topic())
    {admin, _, _} = Fixtures.admin!()
    %{conn: log_in_admin(build_conn(), admin), admin: admin}
  end

  test "a slug is looked up, previewed, and tracked with the chosen timezone", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/channels")

    html = view |> form("#lookup-form", lookup: %{slug: "LiveStreamer"}) |> render_submit()
    assert html =~ "channel-preview"
    assert html =~ "livestreamer"
    assert html =~ "live"

    view |> form("#confirm-form", confirm: %{timezone: "Africa/Tunis"}) |> render_submit()

    channel = Channels.get_by_slug("livestreamer")
    assert channel.active and channel.timezone == "Africa/Tunis"
    assert_receive {:added, id} when id == channel.id
    assert [%{action: "channel.add", target: "livestreamer"} | _] = Audit.recent()
  end

  test "an unknown slug or timezone is refused", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/channels")
    html = view |> form("#lookup-form", lookup: %{slug: "nosuchstreamer"}) |> render_submit()
    assert html =~ "No channel with that slug"

    view |> form("#lookup-form", lookup: %{slug: "offlinestreamer"}) |> render_submit()
    html = view |> form("#confirm-form", confirm: %{timezone: "Mars/Olympus"}) |> render_submit()
    assert html =~ "Unknown timezone"
    assert Channels.get_by_slug("offlinestreamer") == nil
  end

  test "pausing and resuming broadcast the change and keep the row", %{conn: conn} do
    {:ok, channel} = Channels.add("offlinestreamer")
    assert_receive {:added, _}
    {:ok, view, _} = live(conn, "/admin/channels")

    view |> element("#toggle-#{channel.id}") |> render_click()
    refute Channels.get!(channel.id).active
    assert_receive {:removed, id} when id == channel.id

    view |> element("#toggle-#{channel.id}") |> render_click()
    assert Channels.get!(channel.id).active
    assert_receive {:added, ^id}
  end

  test "the timezone can be edited", %{conn: conn} do
    {:ok, channel} = Channels.add("offlinestreamer")
    {:ok, view, _} = live(conn, "/admin/channels")
    view |> element("#channel-#{channel.id} button[phx-click=edit_tz]") |> render_click()
    view |> form("#tz-form-#{channel.id}", %{timezone: "Europe/Paris"}) |> render_submit()
    assert Channels.get!(channel.id).timezone == "Europe/Paris"
  end
end
