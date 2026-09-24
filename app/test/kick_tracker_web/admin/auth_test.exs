defmodule KickTrackerWeb.Admin.AuthTest do
  use KickTrackerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias KickTracker.{Admins, Fixtures}

  test "admin pages send a visitor to the login page", %{conn: conn} do
    for path <- [
          "/admin",
          "/admin/channels",
          "/admin/admins",
          "/admin/account",
          "/admin/dashboard"
        ] do
      assert redirected_to(get(conn, path)) == "/admin/login"
    end
  end

  test "logging in takes the password and a code, and one message for every failure", %{
    conn: conn
  } do
    {admin, password, secret} = Fixtures.admin!("someone@example.com")

    conn2 =
      post(conn, ~p"/admin/login",
        admin: %{
          email: admin.email,
          password: "wrong wrong wrong",
          code: Fixtures.totp_now(secret)
        }
      )

    assert html_response(conn2, 200) =~ "Invalid email, password or code."

    conn2 =
      post(conn, ~p"/admin/login",
        admin: %{email: admin.email, password: password, code: "000000"}
      )

    assert html_response(conn2, 200) =~ "Invalid email, password or code."

    conn =
      post(conn, ~p"/admin/login",
        admin: %{email: admin.email, password: password, code: Fixtures.totp_now(secret)}
      )

    assert redirected_to(conn) == "/admin"
    token = get_session(conn, :admin_token)
    assert Admins.get_by_session_token(token).id == admin.id

    assert [%{action: "login", admin_email: "someone@example.com"} | _] =
             KickTracker.Audit.recent()

    # Logging out ends the session token itself, not only the cookie.
    conn = conn |> recycle() |> delete(~p"/admin/logout")
    assert redirected_to(conn) == "/admin/login"
    assert Admins.get_by_session_token(token) == nil
  end

  test "a logged-in admin skips the login page", %{conn: conn} do
    %{conn: conn} = log_in_admin(%{conn: conn})
    assert redirected_to(get(conn, ~p"/admin/login")) == "/admin"
  end

  test "an invitation link creates an account", %{conn: conn} do
    {:ok, token} = Admins.invite(nil, "new@example.com")
    {:ok, view, html} = live(conn, ~p"/admin/invite/#{token}")
    assert html =~ "new@example.com"

    # The secret shown is the one the account gets.
    secret =
      view
      |> element("#totp-secret")
      |> render()
      |> then(&Regex.run(~r/>\s*([A-Z2-7 ]+)\s*</, &1))
      |> List.last()
      |> String.replace(" ", "")
      |> Base.decode32!(padding: false)

    result =
      view
      |> form("#invite-form",
        admin: %{
          password: "a long enough password",
          password_confirmation: "a long enough password",
          code: Fixtures.totp_now(secret)
        }
      )
      |> render_submit()

    assert {:error, {:redirect, %{to: "/admin/login"}}} = result
    assert [%{email: "new@example.com"}] = Admins.list()
  end

  test "an unknown invitation says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/invite/nope")
    assert html =~ "invalid or has expired"
  end

  describe "admins page" do
    setup :log_in_admin

    test "creates an invitation link shown once, and lists it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/admins")

      html =
        view |> form("#invite-form", invite: %{email: "friend@example.com"}) |> render_submit()

      assert html =~ "/admin/invite/"
      assert html =~ "friend@example.com"
      assert [%{sent_to: "friend@example.com"}] = Admins.list_invites()
    end

    test "disabling an admin ends their sessions", %{conn: conn} do
      {other, _, _} = Fixtures.admin!()
      token = Admins.create_session_token(other)
      {:ok, view, _} = live(conn, ~p"/admin/admins")
      view |> element("#toggle-admin-#{other.id}") |> render_click()
      assert Admins.get_by_session_token(token) == nil
    end
  end
end
