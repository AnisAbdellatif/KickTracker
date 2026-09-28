defmodule KickTrackerWeb.Admin.ApiKeysLiveTest do
  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures

  alias KickTracker.{ApiKeys, Audit}

  setup :log_in_admin

  setup do
    KickTracker.Cache.clear()
    %{channel: channel!(slug: "somestreamer")}
  end

  test "a key is created with what it reaches, shown once, audited", %{conn: conn, channel: c} do
    {:ok, view, _} = live(conn, ~p"/admin/api-keys")
    view |> element("#new-key") |> render_click()
    # "Only these" shows the channels to pick.
    view |> form("#key-form", %{"api_key" => %{"all_channels" => "false"}}) |> render_change()
    assert has_element?(view, "#key-channels")

    view
    |> form("#key-form", %{
      "api_key" => %{
        "name" => "some app",
        "contact" => "someone@example.com",
        "all_channels" => "false",
        "channel_ids" => ["", to_string(c.id)],
        "scopes" => ["", "channels", "viewers"],
        "rate_limit" => "120",
        "history_days" => "30",
        "min_res" => "1h",
        "allowed_cidrs" => "203.0.113.0/24\n198.51.100.7",
        "expires_at" => "2099-12-31"
      }
    })
    |> render_submit()

    shown = view |> element("#created-key input") |> render()
    [_, raw] = Regex.run(~r/value="(kt_[^"]+)"/, shown)

    assert [key] = ApiKeys.list()

    assert %{
             name: "some app",
             all_channels: false,
             scopes: ["channels", "viewers"],
             rate_limit: 120,
             history_days: 30,
             min_res: "1h",
             allowed_cidrs: ["203.0.113.0/24", "198.51.100.7"],
             expires_at: ~U[2100-01-01 00:00:00.000000Z]
           } = key

    assert key.channel_ids == [c.id]
    assert {:ok, _} = ApiKeys.authenticate(raw, {203, 0, 113, 5})
    refute key.token_hash == raw
    assert [%{action: "api_key.create", target: "some app"} | _] = Audit.recent()

    # Gone once dismissed or the page reloads.
    view |> element("#created-key button") |> render_click()
    refute has_element?(view, "#created-key")
    {:ok, _view, html} = live(conn, ~p"/admin/api-keys")
    refute html =~ raw
    assert html =~ key.prefix
  end

  test "a bad address is refused with the form kept", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/api-keys")
    view |> element("#new-key") |> render_click()

    html =
      view
      |> form("#key-form", %{"api_key" => %{"name" => "some app", "allowed_cidrs" => "nope"}})
      |> render_submit()

    assert html =~ "not an address or CIDR: nope"
    assert ApiKeys.list() == []
  end

  test "an admin key is flagged in the form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/api-keys")
    view |> element("#new-key") |> render_click()
    refute has_element?(view, "#admin-key-warning")

    view |> form("#key-form", %{"api_key" => %{"admin" => "true"}}) |> render_change()
    assert has_element?(view, "#admin-key-warning")
    refute has_element?(view, "#key-channels")
  end

  test "a key is edited without changing it, and revoked", %{conn: conn} do
    {:ok, key, raw} = ApiKeys.create(nil, %{name: "some app", scopes: ["channels"]})
    {:ok, view, _} = live(conn, ~p"/admin/api-keys")

    view |> element("#edit-key-#{key.id}") |> render_click()

    view
    |> form("#key-form", %{"api_key" => %{"scopes" => ["", "channels", "live"]}})
    |> render_submit()

    assert ApiKeys.get!(key.id).scopes == ["channels", "live"]
    assert {:ok, _} = ApiKeys.authenticate(raw, {127, 0, 0, 1})
    assert [%{action: "api_key.update"} | _] = Audit.recent()

    view |> element("#revoke-key-#{key.id}") |> render_click()
    assert ApiKeys.get!(key.id).revoked_at
    assert ApiKeys.authenticate(raw, {127, 0, 0, 1}) == :error
    assert [%{action: "api_key.revoke"} | _] = Audit.recent()
    assert view |> element("#api-key-#{key.id}") |> render() =~ "revoked"
  end
end
