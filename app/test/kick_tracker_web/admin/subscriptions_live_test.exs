defmodule KickTrackerWeb.Admin.SubscriptionsLiveTest do
  @moduledoc "The subscriptions page against the fake Kick."

  use KickTracker.SimCase
  @moduletag :capture_log

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import KickTrackerWeb.ConnCase, only: [log_in_admin: 2]

  alias KickTracker.{Channels, Fixtures}
  alias KickTracker.Kick.API
  alias KickTracker.Workers.SubscriptionSync

  @endpoint KickTrackerWeb.Endpoint

  describe "with Kick answering" do
    setup do
      start_sim([
        [slug: "livestreamer", schedule: :always],
        [slug: "offlinestreamer", schedule: :never]
      ])

      start_supervised!(KickTracker.Kick.Token)
      {admin, _, _} = Fixtures.admin!()
      {:ok, live} = Channels.add("livestreamer")
      {:ok, off} = Channels.add("offlinestreamer")
      :ok = SubscriptionSync.perform(%Oban.Job{})
      %{conn: log_in_admin(build_conn(), admin), live: live, off: off}
    end

    test "each channel's subscriptions, counted; the incomplete ones on their own", %{
      conn: conn,
      live: live,
      off: off
    } do
      # One of the offline channel's subscriptions goes missing.
      {:ok, subs} = API.subscriptions()
      sub = Enum.find(subs, &(&1["broadcaster_user_id"] == off.kick_user_id))
      :ok = API.unsubscribe([sub["id"]])

      {:ok, view, _} = live(conn, "/admin/subscriptions")
      n = length(SubscriptionSync.events())
      assert has_element?(view, "#subscriptions-#{live.id}", "#{n}/#{n}")
      assert has_element?(view, "#subscriptions-#{off.id}", "#{n - 1}/#{n}")
      assert has_element?(view, "#subscriptions-summary", "Missing")

      view |> element("#subscriptions-incomplete") |> render_click()
      refute has_element?(view, "#subscriptions-#{live.id}")
      assert has_element?(view, "#subscriptions-#{off.id}")

      view |> element("#subscriptions-incomplete") |> render_click()
      view |> element("#subscriptions-search") |> render_change(%{"q" => "live"})
      assert has_element?(view, "#subscriptions-#{live.id}")
      refute has_element?(view, "#subscriptions-#{off.id}")
    end
  end

  test "when Kick doesn't answer, the page says so instead of showing every one missing" do
    previous = Application.get_env(:kick_tracker, :kick)
    on_exit(fn -> Application.put_env(:kick_tracker, :kick, previous) end)

    Application.put_env(
      :kick_tracker,
      :kick,
      Keyword.merge(previous, api_url: "http://127.0.0.1:1", id_url: "http://127.0.0.1:1")
    )

    {admin, _, _} = Fixtures.admin!()
    {:ok, view, _} = live(log_in_admin(build_conn(), admin), "/admin/subscriptions")
    assert has_element?(view, "#subscriptions-error", "Kick didn't answer")
    refute has_element?(view, "#subscriptions")
  end
end
