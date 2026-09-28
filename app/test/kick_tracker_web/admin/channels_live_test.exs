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

  test "how much the public site shows is chosen per channel, audited", %{conn: conn} do
    {:ok, channel} = Channels.add("offlinestreamer")
    {:ok, view, _} = live(conn, "/admin/channels")

    view |> form("#visibility-#{channel.id}", %{visibility: "live_only"}) |> render_change()
    assert %{visibility: :live_only, public: false} = Channels.get!(channel.id)

    assert [%{action: "channel.visibility", target: "offlinestreamer", details: details} | _] =
             Audit.recent()

    assert details == %{"from" => "public", "to" => "live_only"}

    view |> element("#channels-show-live_only") |> render_click()
    assert has_element?(view, "#channel-#{channel.id}")
    view |> element("#channels-show-hidden") |> render_click()
    refute has_element?(view, "#channel-#{channel.id}")

    view |> element("#channels-show-all") |> render_click()
    view |> form("#visibility-#{channel.id}", %{visibility: "hidden"}) |> render_change()
    assert %{visibility: :hidden, public: false} = Channels.get!(channel.id)
    assert has_element?(view, "#channel-#{channel.id}")

    view |> form("#visibility-#{channel.id}", %{visibility: "public"}) |> render_change()
    assert %{visibility: :public, public: true} = Channels.get!(channel.id)
  end

  test "the timezone can be edited", %{conn: conn} do
    {:ok, channel} = Channels.add("offlinestreamer")
    {:ok, view, _} = live(conn, "/admin/channels")
    view |> element("#channel-#{channel.id} button[phx-click=edit_tz]") |> render_click()
    view |> form("#tz-form-#{channel.id}", %{timezone: "Europe/Paris"}) |> render_submit()
    assert Channels.get!(channel.id).timezone == "Europe/Paris"
  end

  test "the list is searched and filtered by state", %{conn: conn} do
    {:ok, live} = Channels.add("livestreamer")
    {:ok, off} = Channels.add("offlinestreamer")
    {:ok, _} = Channels.set_active(off, false)
    {:ok, view, _} = live(conn, "/admin/channels")

    view |> element("#channels-show-paused") |> render_click()
    refute has_element?(view, "#channel-#{live.id}")
    assert has_element?(view, "#channel-#{off.id}")

    view |> element("#channels-show-all") |> render_click()
    view |> element("#channels-search") |> render_change(%{"q" => "LIVE"})
    assert has_element?(view, "#channel-#{live.id}")
    refute has_element?(view, "#channel-#{off.id}")
  end

  test "deleting asks in a dialog for the slug, then queues the deletion", %{conn: conn} do
    {:ok, channel} = Channels.add("offlinestreamer")
    {:ok, view, _} = live(conn, "/admin/channels")

    view |> element("#ask-delete-#{channel.id}") |> render_click()
    assert has_element?(view, "#delete-dialog", "Delete offlinestreamer and all its data?")

    html = view |> form("#delete-#{channel.id}", %{slug: "wrong"}) |> render_submit()
    assert html =~ "Type the slug exactly"

    view |> form("#delete-#{channel.id}", %{slug: "offlinestreamer"}) |> render_submit()
    refute has_element?(view, "#delete-dialog")
    assert [%{action: "channel.delete_data", target: "offlinestreamer"} | _] = Audit.recent()
  end
end
