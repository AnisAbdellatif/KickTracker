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

  def create(conn, params) do
    cond do
      RateLimit.login_banned?(conn) ->
        conn |> send_resp(429, "Too many failed logins. Try again later.") |> halt()

      login_params?(params) ->
        %{"email" => email, "password" => password, "code" => code} = params["admin"]
        authenticate(conn, email, password, code)

      # Not three strings (a field missing, or a map or list where a string
      # goes): a failure like any other, answered 400, never a crash.
      true ->
        RateLimit.login_failed(conn)

        conn
        |> put_status(:bad_request)
        |> put_flash(:error, gettext("Invalid email, password or code."))
        |> render(:new,
          form: Phoenix.Component.to_form(%{}, as: "admin"),
          page_title: "Admin login"
        )
    end
  end

  defp login_params?(%{"admin" => %{"email" => e, "password" => p, "code" => c}}),
    do: is_binary(e) and is_binary(p) and is_binary(c)

  defp login_params?(_), do: false

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
