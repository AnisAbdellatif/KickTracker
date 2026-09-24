defmodule KickTrackerWeb.Admin.InviteLive do
  @moduledoc """
  Accepting an invitation: choose a password and enroll an authenticator
  app, proven by entering a current code.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Admins, Audit}
  alias KickTracker.Admins.TOTP

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    invite = Admins.get_invite(token)

    # The secret is made once, on the connected mount, so the one shown is
    # the one kept.
    secret = if invite && connected?(socket), do: TOTP.new_secret()

    {:ok,
     socket
     |> assign(page_title: gettext("Accept invitation"), invite: invite, secret: secret)
     |> assign(form: to_form(%{}, as: "admin"))}
  end

  @impl true
  def handle_event("save", %{"admin" => params}, socket) do
    %{invite: invite, secret: secret} = socket.assigns

    case Admins.accept_invite(invite, secret, params) do
      {:ok, admin} ->
        Audit.log(admin, "admin.accept_invite", admin.email)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Account created. Log in with your password and a code."))
         |> redirect(to: ~p"/admin/login")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "admin"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.bare flash={@flash}>
      <div class="mx-auto max-w-md">
        <%= if @invite do %>
          <h1 class="text-xl font-semibold">{gettext("Create your admin account")}</h1>
          <p class="mt-1 text-sm opacity-70">{@invite.sent_to}</p>

          <div :if={@secret} class="mt-6 card-surface p-4 text-sm">
            <p class="font-medium">{gettext("1. Add this key to your authenticator app")}</p>
            <p id="totp-secret" class="mt-2 break-all font-mono text-base tracking-wider">
              {@secret
              |> TOTP.encode_secret()
              |> String.graphemes()
              |> Enum.chunk_every(4)
              |> Enum.map_join(" ", &Enum.join/1)}
            </p>
            <p class="mt-2 break-all text-xs opacity-60">
              {TOTP.uri(@secret, @invite.sent_to, KickTrackerWeb.Layouts.site_name())}
            </p>
          </div>

          <.form for={@form} id="invite-form" phx-submit="save" class="mt-6 space-y-2">
            <p class="text-sm font-medium">{gettext("2. Choose a password and enter a code")}</p>
            <.input
              field={@form[:password]}
              type="password"
              label={gettext("Password (12+ characters)")}
              autocomplete="new-password"
              required
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label={gettext("Confirm password")}
              autocomplete="new-password"
              required
            />
            <.input
              field={@form[:code]}
              type="text"
              label={gettext("Code from the app")}
              inputmode="numeric"
              autocomplete="one-time-code"
              required
            />
            <.input :if={@form.errors[:email]} field={@form[:email]} type="hidden" />
            <p :for={{msg, _} <- Keyword.get_values(@form.errors, :email)} class="text-sm text-error">
              {msg}
            </p>
            <.button class="btn btn-primary w-full mt-4" phx-disable-with={gettext("Creating…")}>
              {gettext("Create account")}
            </.button>
          </.form>
        <% else %>
          <h1 class="text-xl font-semibold">
            {gettext("This invitation is invalid or has expired.")}
          </h1>
          <p class="mt-2 text-sm opacity-70">{gettext("Ask an admin for a new one.")}</p>
        <% end %>
      </div>
    </Layouts.bare>
    """
  end
end
