defmodule KickTrackerWeb.Admin.AccountLive do
  @moduledoc "The admin's own account: change password (ends other sessions)."

  use KickTrackerWeb, :live_view

  alias KickTracker.{Admins, Audit}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Account"), form: to_form(%{}, as: "password"))}
  end

  @impl true
  def handle_event("save", %{"password" => %{} = params}, socket) do
    admin = socket.assigns.current_admin

    case Admins.change_password(admin, params["current_password"], params) do
      {:ok, _admin} ->
        Audit.log(admin, "admin.change_password", admin.email)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Password changed. Please log in again."))
         |> redirect(to: ~p"/admin/login")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "password"))}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:account}>
      <.page_header title={gettext("Your account")} icon="hero-user-circle">
        <:subtitle>{gettext("Signed in with a password and an authenticator code.")}</:subtitle>
      </.page_header>

      <div class="grid max-w-3xl items-start gap-6 md:grid-cols-2">
        <.panel title={gettext("Account")} icon="hero-identification">
          <div class="flex items-center gap-3">
            <.avatar name={@current_admin.email} class="size-10 text-base" />
            <div class="min-w-0">
              <p class="truncate font-medium">{@current_admin.email}</p>
              <p class="text-muted text-xs">
                {gettext("Admin since %{date}",
                  date: Calendar.strftime(@current_admin.inserted_at, "%Y-%m-%d")
                )}
              </p>
            </div>
          </div>
        </.panel>

        <.panel title={gettext("Password")} icon="hero-key">
          <.form for={@form} id="password-form" phx-submit="save" class="space-y-2">
            <.input
              field={@form[:current_password]}
              type="password"
              label={gettext("Current password")}
              autocomplete="current-password"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label={gettext("New password (12+ characters)")}
              autocomplete="new-password"
              required
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label={gettext("Confirm new password")}
              autocomplete="new-password"
              required
            />
            <.button class="btn btn-primary mt-2">{gettext("Change password")}</.button>
          </.form>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
