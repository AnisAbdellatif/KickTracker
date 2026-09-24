defmodule KickTrackerWeb.AdminAuth do
  @moduledoc """
  Admin sessions (project.md §13.8): a random token in the signed session
  cookie, looked up on every request and LiveView mount. Logging out
  deletes the token and disconnects the admin's live pages.

  A live page is also held to its session while open: disabling an admin
  or changing a password disconnects their pages (`Admins.end_sessions/1`),
  every event is checked against the token again before it runs, and the
  page leaves when the token expires.
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
    |> put_session(:live_socket_id, Admins.live_socket_id(token))
    |> redirect(to: ~p"/admin")
  end

  @doc "Logs out: deletes the token and disconnects the admin's live pages."
  def log_out(conn) do
    if token = get_session(conn, :admin_token) do
      Admins.delete_session_token(token)
      Admins.end_sessions([token])
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

  @doc """
  LiveView `on_mount`: `:require_admin` for the admin pages (and the
  dashboards mounted under `/admin`).
  """
  def on_mount(:require_admin, _params, session, socket) do
    token = session["admin_token"]

    socket =
      Phoenix.Component.assign_new(socket, :current_admin, fn ->
        if is_binary(token), do: Admins.get_by_session_token(token)
      end)

    if socket.assigns.current_admin do
      {:cont, hold_to_session(socket, token)}
    else
      {:halt, to_login(socket)}
    end
  end

  def on_mount(:public, _params, _session, socket), do: {:cont, socket}

  # Every event checks the session again (one indexed query; admin events
  # are few) before the page acts on it, and the page leaves at the
  # token's expiry. This is behind the disconnect broadcast, not instead
  # of it: a page whose socket wasn't told still can't act.
  defp hold_to_session(socket, token) do
    admin_id = socket.assigns.current_admin.id

    if Phoenix.LiveView.connected?(socket), do: schedule_check(token)

    socket
    |> Phoenix.LiveView.attach_hook(:admin_session, :handle_event, fn event, params, socket ->
      if valid?(token, admin_id) do
        audit_dashboard_event(socket, event, params)
        {:cont, socket}
      else
        {:halt, to_login(socket)}
      end
    end)
    |> Phoenix.LiveView.attach_hook(:admin_session_expiry, :handle_info, fn
      {__MODULE__, :check_session}, socket ->
        if valid?(token, admin_id) do
          schedule_check(token)
          {:halt, socket}
        else
          {:halt, to_login(socket)}
        end

      _message, socket ->
        {:cont, socket}
    end)
  end

  defp valid?(token, admin_id) do
    match?(%{id: ^admin_id}, is_binary(token) && Admins.get_by_session_token(token))
  end

  # At the token's expiry, and at least hourly (a timer can't wait weeks).
  defp schedule_check(token) do
    ms =
      case is_binary(token) && Admins.session_expires_at(token) do
        %DateTime{} = at -> DateTime.diff(at, DateTime.utc_now(), :millisecond) + 1_000
        _ -> 0
      end

    Process.send_after(self(), {__MODULE__, :check_session}, ms |> max(0) |> min(3_600_000))
  end

  defp to_login(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, "Please log in.")
    |> Phoenix.LiveView.redirect(to: ~p"/admin/login")
  end

  # The ErrorTracker dashboard changes an error's state without telling us
  # who did it: its events are audited here, on their way in.
  @error_actions ~w(resolve unresolve mute unmute)

  defp audit_dashboard_event(socket, event, params) when event in @error_actions do
    if socket.view in [ErrorTracker.Web.Live.Dashboard, ErrorTracker.Web.Live.Show] do
      id =
        case {params, socket.assigns[:error]} do
          {%{"error_id" => id}, _} -> to_string(id)
          {_, %{id: id}} -> to_string(id)
          _ -> nil
        end

      KickTracker.Audit.log(socket.assigns.current_admin, "error.#{event}", id)
    end

    :ok
  end

  defp audit_dashboard_event(_socket, _event, _params), do: :ok
end
