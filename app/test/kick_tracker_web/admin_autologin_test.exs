defmodule KickTrackerWeb.AdminAutologinTest do
  @moduledoc "The sandbox's automatic admin sign-in, and what keeps it out of production."

  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias KickTracker.{Admins, Audit}
  alias KickTrackerWeb.AdminAuth

  @email "admin@sandbox.localhost"

  test "it can only be configured for a site served on this machine" do
    assert AdminAuth.autologin_config!(nil, "stats.example.org") == nil
    assert AdminAuth.autologin_config!("  ", "stats.example.org") == nil
    assert AdminAuth.autologin_config!(@email, "localhost") == %{email: @email, host: "localhost"}

    assert_raise RuntimeError, ~r/sandbox only/, fn ->
      AdminAuth.autologin_config!(@email, "stats.example.org")
    end
  end

  describe "on" do
    setup do
      Application.put_env(:kick_tracker, :admin_autologin, %{email: @email, host: "localhost"})
      on_exit(fn -> Application.delete_env(:kick_tracker, :admin_autologin) end)
    end

    test "a visitor on the local host is the sandbox admin, pages and live pages; one account",
         %{conn: conn} do
      conn = get(%{conn | host: "localhost"}, ~p"/admin/chat-log")
      assert html_response(conn, 200) =~ "Chat log"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "signed in automatically"

      {:ok, view, _} = live(recycle(conn), ~p"/admin/chat-log")
      render_click(view, "settings_show", %{"show" => "on"})

      conn = get(%{build_conn() | host: "localhost"}, ~p"/admin/login")
      assert redirected_to(conn) == ~p"/admin"
      assert [%{email: @email}] = Admins.list()

      # What it does is audited under its name.
      channel = KickTracker.Fixtures.channel!()
      {:ok, view, _} = live(recycle(conn), ~p"/admin/chat-log")
      view |> element("#chat-log-toggle-#{channel.id}") |> render_click()
      assert [%{admin_email: @email, action: "chat_log.configure"} | _] = Audit.recent()
    end

    test "another host (a tunnel to the ingress, say) is not let in", %{conn: conn} do
      conn = get(%{conn | host: "127.0.0.1"}, ~p"/admin/chat-log")
      assert redirected_to(conn) =~ "/admin/login"
      assert Admins.list() == []
    end
  end

  test "off, the admin needs to sign in", %{conn: conn} do
    conn = get(%{conn | host: "localhost"}, ~p"/admin/chat-log")
    assert redirected_to(conn) =~ "/admin/login"
  end
end
