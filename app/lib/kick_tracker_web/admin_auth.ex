defmodule KickTrackerWeb.AdminAuth do
  @moduledoc """
  Admin sessions (project.md §13.8): a random token in the signed session
  cookie, looked up on every request and LiveView mount. Logging out
  deletes the token and disconnects the admin's live pages.
  """

  use KickTrackerWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias KickTracker.Admins

  @doc "Logs an admin in: a fresh session with a new token."
  def log_in(conn, admin) do
    token = Admins.create_session_token(admin)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:admin_token, token)
    |> put_session(:live_socket_id, socket_id(token))
    |> redirect(to: ~p"/admin")
  end

  @doc "Logs out: deletes the token and disconnects the admin's live pages."
  def log_out(conn) do
    if token = get_session(conn, :admin_token) do
      Admins.delete_session_token(token)
      KickTrackerWeb.Endpoint.broadcast(socket_id(token), "disconnect", %{})
    end

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: ~p"/admin/login")
  end

  @doc "Plug: assigns `current_admin` (or nil)."
  def fetch_current_admin(conn, _opts) do
    admin = if token = get_session(conn, :admin_token), do: Admins.get_by_session_token(token)
    assign(conn, :current_admin, admin)
  end

  @doc "Plug: only admins get through."
  def require_admin(conn, _opts) do
    if conn.assigns[:current_admin] do
      conn
    else
      conn
      |> put_flash(:error, "Please log in.")
      |> redirect(to: ~p"/admin/login")
      |> halt()
    end
  end

  @doc "Plug: a logged-in admin skips the login page."
  def redirect_if_admin(conn, _opts) do
    if conn.assigns[:current_admin], do: conn |> redirect(to: ~p"/admin") |> halt(), else: conn
  end

  @doc "LiveView `on_mount`: `:require_admin` for the admin pages."
  def on_mount(:require_admin, _params, session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :current_admin, fn ->
        if token = session["admin_token"], do: Admins.get_by_session_token(token)
      end)

    if socket.assigns.current_admin do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Please log in.")
       |> Phoenix.LiveView.redirect(to: ~p"/admin/login")}
    end
  end

  def on_mount(:public, _params, _session, socket), do: {:cont, socket}

  defp socket_id(token), do: "admin_sessions:#{Base.url_encode64(token)}"
end
