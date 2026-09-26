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
  def handle_event("invite", %{"invite" => %{"email" => email}}, socket) when is_binary(email) do
    admin = socket.assigns.current_admin

    case Admins.invite(admin, email) do
      {:ok, token} ->
        Audit.log(admin, "admin.invite", String.trim(email))

        {:noreply,
         socket
         |> assign(
           link: url(~p"/admin/invite?#{[token: token]}"),
           form: to_form(%{}, as: "invite")
         )
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "invite"))}
    end
  end

  def handle_event("invite", _params, socket), do: {:noreply, socket}

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
      <.page_header title={gettext("Admins")} icon="hero-user-group">
        <:subtitle>
          {gettext(
            "No public sign-up: invite an admin by email and send them the link yourself. Each signs in with a password and an authenticator code."
          )}
        </:subtitle>
      </.page_header>

      <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
        <.panel title={gettext("Admins")} icon="hero-user-group" flush>
          <div class="overflow-x-auto">
            <table id="admins" class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Email")}</th>
                  <th>{gettext("Invited by")}</th>
                  <th>{gettext("Since")}</th>
                  <th>{gettext("Status")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={a <- @admins} id={"admins-#{a.id}"}>
                  <td>
                    <span class="flex items-center gap-2">
                      <.avatar name={a.email} class="size-7 text-xs" />
                      <span class="truncate">{a.email}</span>
                      <.status_pill :if={a.id == @current_admin.id} tone={:info}>
                        {gettext("you")}
                      </.status_pill>
                    </span>
                  </td>
                  <td class="text-muted text-sm">{(a.invited_by && a.invited_by.email) || "–"}</td>
                  <td class="text-sm tabular-nums">{Calendar.strftime(a.inserted_at, "%Y-%m-%d")}</td>
                  <td>
                    <.status_pill tone={if a.disabled_at, do: :neutral, else: :ok}>
                      {if a.disabled_at, do: gettext("disabled"), else: gettext("active")}
                    </.status_pill>
                  </td>
                  <td class="text-end">
                    <button
                      :if={a.id != @current_admin.id}
                      id={"toggle-admin-#{a.id}"}
                      phx-click="toggle"
                      phx-value-id={a.id}
                      data-confirm={gettext("Are you sure?")}
                      class={["btn btn-ghost btn-xs", !a.disabled_at && "text-error"]}
                    >
                      {if a.disabled_at, do: gettext("Enable"), else: gettext("Disable")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel title={gettext("Invite an admin")} icon="hero-envelope">
          <.form for={@form} id="invite-form" phx-submit="invite" class="flex items-end gap-2">
            <div class="flex-1">
              <.input field={@form[:email]} type="email" label={gettext("Email")} required />
            </div>
            <.button class="btn btn-primary mb-2">{gettext("Create link")}</.button>
          </.form>
          <div
            :if={@link}
            id="invite-link"
            class="alert alert-warning mt-3 flex-col items-start text-sm"
          >
            <p>{gettext("Send this link; it works once, for 7 days, and won't be shown again:")}</p>
            <input
              value={@link}
              readonly
              class="input input-sm w-full font-mono"
              aria-label={gettext("Invitation link")}
            />
          </div>

          <div :if={@invites != []} class="mt-4 border-t border-base-300 pt-3">
            <p class="text-muted mb-2 text-xs font-semibold uppercase tracking-wide">
              {gettext("Pending")}
            </p>
            <ul id="invites" class="space-y-2">
              <li :for={i <- @invites} class="flex items-center gap-2 text-sm">
                <.icon name="hero-clock" class="text-muted size-4" />
                <span class="min-w-0 flex-1">
                  <span class="block truncate">{i.sent_to}</span>
                  <span class="text-muted text-xs">
                    {Calendar.strftime(i.inserted_at, "%Y-%m-%d %H:%M")} · {i.admin && i.admin.email}
                  </span>
                </span>
                <button
                  id={"revoke-#{i.id}"}
                  phx-click="revoke"
                  phx-value-id={i.id}
                  class="btn btn-ghost btn-xs"
                >
                  {gettext("Revoke")}
                </button>
              </li>
            </ul>
          </div>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
