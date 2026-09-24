defmodule KickTrackerWeb.Admin.AdminsLive do
  @moduledoc "Admins invite admins (project.md §13.8); an invitation link is shown once."

  use KickTrackerWeb, :live_view

  alias KickTracker.{Admins, Audit}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Admins"), link: nil, form: to_form(%{}, as: "invite"))
     |> load()}
  end

  defp load(socket), do: assign(socket, admins: Admins.list(), invites: Admins.list_invites())

  @impl true
  def handle_event("invite", %{"invite" => %{"email" => email}}, socket) do
    admin = socket.assigns.current_admin

    case Admins.invite(admin, email) do
      {:ok, token} ->
        Audit.log(admin, "admin.invite", String.trim(email))

        {:noreply,
         socket
         |> assign(link: url(~p"/admin/invite/#{token}"), form: to_form(%{}, as: "invite"))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "invite"))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Admins.revoke_invite(String.to_integer(id))
    Audit.log(socket.assigns.current_admin, "admin.revoke_invite", id)
    {:noreply, load(socket)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    current = socket.assigns.current_admin
    admin = Admins.get!(String.to_integer(id))

    if admin.id == current.id do
      {:noreply, put_flash(socket, :error, gettext("You can't disable yourself."))}
    else
      disable? = is_nil(admin.disabled_at)
      {:ok, admin} = Admins.set_disabled(admin, disable?)
      Audit.log(current, if(disable?, do: "admin.disable", else: "admin.enable"), admin.email)
      {:noreply, load(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:admins}>
      <.header>
        {gettext("Admins")}
        <:subtitle>
          {gettext("No public sign-up: invite an admin by email and send them the link yourself.")}
        </:subtitle>
      </.header>

      <.table id="admins" rows={@admins}>
        <:col :let={a} label={gettext("Email")}>{a.email}</:col>
        <:col :let={a} label={gettext("Invited by")}>{a.invited_by && a.invited_by.email}</:col>
        <:col :let={a} label={gettext("Since")}>{Calendar.strftime(a.inserted_at, "%Y-%m-%d")}</:col>
        <:col :let={a} label={gettext("Status")}>
          {if a.disabled_at, do: gettext("disabled"), else: gettext("active")}
        </:col>
        <:action :let={a}>
          <button
            :if={a.id != @current_admin.id}
            id={"toggle-admin-#{a.id}"}
            phx-click="toggle"
            phx-value-id={a.id}
            data-confirm={gettext("Are you sure?")}
            class="btn btn-ghost btn-xs"
          >
            {if a.disabled_at, do: gettext("Enable"), else: gettext("Disable")}
          </button>
        </:action>
      </.table>

      <section class="mt-10 max-w-xl">
        <h2 class="font-semibold">{gettext("Invite an admin")}</h2>
        <.form for={@form} id="invite-form" phx-submit="invite" class="mt-3 flex items-end gap-2">
          <div class="flex-1">
            <.input field={@form[:email]} type="email" label={gettext("Email")} required />
          </div>
          <.button class="btn btn-primary mb-2">{gettext("Create link")}</.button>
        </.form>
        <div :if={@link} id="invite-link" class="mt-3 rounded-box border border-warning p-3 text-sm">
          <p>{gettext("Send this link; it works once, for 7 days, and won't be shown again:")}</p>
          <p class="mt-2 break-all font-mono">{@link}</p>
        </div>

        <.table :if={@invites != []} id="invites" rows={@invites}>
          <:col :let={i} label={gettext("Pending for")}>{i.sent_to}</:col>
          <:col :let={i} label={gettext("By")}>{i.admin && i.admin.email}</:col>
          <:col :let={i} label={gettext("Created")}>
            {Calendar.strftime(i.inserted_at, "%Y-%m-%d %H:%M")}
          </:col>
          <:action :let={i}>
            <button
              id={"revoke-#{i.id}"}
              phx-click="revoke"
              phx-value-id={i.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Revoke")}
            </button>
          </:action>
        </.table>
      </section>
    </Layouts.admin>
    """
  end
end
