defmodule KickTrackerWeb.Admin.SessionController do
  use KickTrackerWeb, :controller

  alias KickTracker.{Admins, Audit}
  alias KickTrackerWeb.AdminAuth
  alias KickTrackerWeb.Plugs.RateLimit

  def new(conn, _params) do
    render(conn, :new,
      form: Phoenix.Component.to_form(%{}, as: "admin"),
      page_title: "Admin login"
    )
  end

  def create(conn, %{"admin" => %{"email" => email, "password" => password, "code" => code}}) do
    if RateLimit.login_banned?(conn) do
      conn |> send_resp(429, "Too many failed logins. Try again later.") |> halt()
    else
      authenticate(conn, email, password, code)
    end
  end

  defp authenticate(conn, email, password, code) do
    case Admins.authenticate(email, password, code) do
      {:ok, admin} ->
        Audit.log(admin, "login")
        AdminAuth.log_in(conn, admin)

      {:error, :invalid} ->
        RateLimit.login_failed(conn)

        # One message for every failure: nothing says which factor was wrong.
        conn
        |> put_flash(:error, gettext("Invalid email, password or code."))
        |> render(:new,
          form: Phoenix.Component.to_form(%{"email" => email}, as: "admin"),
          page_title: "Admin login"
        )
    end
  end

  def delete(conn, _params) do
    if admin = conn.assigns[:current_admin], do: Audit.log(admin, "logout")

    conn
    |> put_flash(:info, gettext("Logged out."))
    |> AdminAuth.log_out()
  end
end
