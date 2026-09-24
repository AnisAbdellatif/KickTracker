defmodule KickTrackerWeb.Admin.AuthTest do
  use KickTrackerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  alias KickTracker.{Admins, Audit, Fixtures, Repo}
  alias KickTracker.Admins.AdminToken

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

  test "a malformed login is a 400 and a failure, not a crash", %{conn: conn} do
    for admin <- [
          %{email: %{x: "a"}, password: "p", code: "1"},
          %{email: "a@example.com", password: ["p"], code: "1"},
          %{email: "a@example.com", password: "p", code: %{c: "1"}},
          %{email: "a@example.com"}
        ] do
      assert html_response(post(conn, ~p"/admin/login", admin: admin), 400) =~
               "Invalid email, password or code."
    end

    assert html_response(post(conn, ~p"/admin/login", %{}), 400)
  end

  test "a logged-in admin skips the login page", %{conn: conn} do
    %{conn: conn} = log_in_admin(%{conn: conn})
    assert redirected_to(get(conn, ~p"/admin/login")) == "/admin"
  end

  test "an invitation link creates an account", %{conn: conn} do
    {:ok, token} = Admins.invite(nil, "new@example.com")
    {:ok, view, html} = live(conn, ~p"/admin/invite?#{[token: token]}")
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
    {:ok, _view, html} = live(conn, ~p"/admin/invite?token=nope")
    assert html =~ "invalid or has expired"
    {:ok, _view, html} = live(conn, ~p"/admin/invite")
    assert html =~ "invalid or has expired"
  end

  test "a link from before, with the token in the path, still opens", %{conn: conn} do
    {:ok, token} = Admins.invite(nil, "new@example.com")
    {:ok, _view, html} = live(conn, ~p"/admin/invite/#{token}")
    assert html =~ "new@example.com"
  end

  test "an invitation revoked or expired while its page is open can't be accepted", %{
    conn: conn
  } do
    for spoil <- [
          fn invite -> Admins.revoke_invite(invite.id) end,
          fn invite ->
            Repo.update_all(
              from(t in AdminToken, where: t.id == ^invite.id),
              set: [inserted_at: DateTime.add(DateTime.utc_now(), -8 * 24 * 3600)]
            )
          end
        ] do
      email = "late#{System.unique_integer([:positive])}@example.com"
      {:ok, token} = Admins.invite(nil, email)
      invite = Admins.get_invite(token)
      {:ok, view, _html} = live(conn, ~p"/admin/invite?#{[token: token]}")
      secret = shown_secret(view)
      spoil.(invite)

      html =
        view
        |> form("#invite-form",
          admin: %{
            password: "a long enough password",
            password_confirmation: "a long enough password",
            code: Fixtures.totp_now(secret)
          }
        )
        |> render_submit()

      assert html =~ "invitation already used or expired"
      refute Enum.any?(Admins.list(), &(&1.email == email))
    end
  end

  defp shown_secret(view) do
    view
    |> element("#totp-secret")
    |> render()
    |> then(&Regex.run(~r/>\s*([A-Z2-7 ]+)\s*</, &1))
    |> List.last()
    |> String.replace(" ", "")
    |> Base.decode32!(padding: false)
  end

  describe "an open admin page is held to its session" do
    setup %{conn: _} do
      {admin, password, _secret} = Fixtures.admin!()
      token = Admins.create_session_token(admin)

      conn =
        Plug.Test.init_test_session(build_conn(),
          admin_token: token,
          live_socket_id: Admins.live_socket_id(token)
        )

      Phoenix.PubSub.subscribe(KickTracker.PubSub, Admins.live_socket_id(token))
      %{admin: admin, password: password, token: token, admin_conn: conn}
    end

    test "disabling the admin disconnects the page, refuses its events and revokes their invitations",
         %{admin: admin, admin_conn: admin_conn} do
      {:ok, _} = Admins.invite(admin, "pending@example.com")
      {:ok, view, _} = live(admin_conn, ~p"/admin/admins")

      # Another admin disables them from their own page.
      %{conn: other_conn} = log_in_admin(%{conn: build_conn()})
      {:ok, other_view, _} = live(other_conn, ~p"/admin/admins")
      other_view |> element("#toggle-admin-#{admin.id}") |> render_click()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert Admins.list_invites() == []

      # A page whose socket wasn't closed still can't act.
      assert {:error, {:redirect, %{to: "/admin/login"}}} =
               view
               |> form("#invite-form", invite: %{email: "friend@example.com"})
               |> render_submit()

      assert Admins.list_invites() == []
    end

    test "changing the password disconnects the admin's pages", %{
      admin: admin,
      password: password,
      admin_conn: admin_conn
    } do
      {:ok, view, _} = live(admin_conn, ~p"/admin/admins")

      assert {:ok, _} =
               Admins.change_password(admin, password, %{
                 "password" => "a brand new password",
                 "password_confirmation" => "a brand new password"
               })

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert {:error, {:redirect, %{to: "/admin/login"}}} =
               view
               |> element("#invite-form")
               |> render_submit(%{invite: %{email: "x@example.com"}})
    end

    test "a page left open leaves when its session expires", %{
      token: token,
      admin_conn: admin_conn
    } do
      {:ok, view, _} = live(admin_conn, ~p"/admin/admins")

      # Still valid: the check keeps the page.
      send(view.pid, {KickTrackerWeb.AdminAuth, :check_session})
      assert render(view) =~ "Invite an admin"

      Repo.update_all(from(t in AdminToken, where: t.token == ^token),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -15 * 24 * 3600)]
      )

      send(view.pid, {KickTrackerWeb.AdminAuth, :check_session})
      assert_redirect(view, "/admin/login")
    end

    test "the error dashboard's actions are audited", %{admin_conn: admin_conn} do
      error =
        Repo.insert!(%ErrorTracker.Error{
          kind: "RuntimeError",
          reason: "boom",
          source_line: "lib/some.ex:1",
          source_function: "Some.fun/0",
          fingerprint: Base.encode16(:crypto.strong_rand_bytes(16)),
          last_occurrence_at: DateTime.utc_now(),
          muted: false
        })

      {:ok, view, _} = live(admin_conn, "/admin/errors")
      render_click(view, "resolve", %{"error_id" => to_string(error.id)})
      assert [%{action: "error.resolve", target: target} | _] = Audit.recent()
      assert target == to_string(error.id)
      assert Repo.get!(ErrorTracker.Error, error.id).status == :resolved
    end
  end

  describe "admins page" do
    setup :log_in_admin

    test "creates an invitation link shown once, and lists it", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/admins")

      html =
        view |> form("#invite-form", invite: %{email: "friend@example.com"}) |> render_submit()

      # The token travels in the query, which request logs leave out.
      assert html =~ "/admin/invite?token="
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
