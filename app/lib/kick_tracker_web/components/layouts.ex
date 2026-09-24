defmodule KickTrackerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use KickTrackerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc "The site's name, from configuration (`SITE_NAME`); never Kick's (project.md §18.3)."
  def site_name, do: Application.get_env(:kick_tracker, :site_name, "Stream Tracker")

  @doc """
  The public site's layout.

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil
  attr :wide, :boolean, default: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-base-300">
      <nav class="mx-auto flex max-w-7xl items-center gap-4 px-4 py-3 sm:px-6">
        <.link navigate={~p"/"} class="text-base font-semibold tracking-tight">{site_name()}</.link>
        <div class="flex flex-1 items-center gap-3 text-sm">
          <.link navigate={~p"/"} class="opacity-80 hover:opacity-100">{gettext("Live")}</.link>
          <.link navigate={~p"/compare"} class="opacity-80 hover:opacity-100">
            {gettext("Compare")}
          </.link>
          <.link navigate={~p"/about/methodology"} class="opacity-80 hover:opacity-100">
            {gettext("Methodology")}
          </.link>
        </div>
        <form action={~p"/search"} method="get" class="hidden sm:block" role="search">
          <input
            type="search"
            name="q"
            placeholder={gettext("Find a channel")}
            class="input input-sm w-44"
            aria-label={gettext("Find a channel")}
          />
        </form>
        <.theme_toggle />
      </nav>
    </header>
    <main class={["mx-auto px-4 py-6 sm:px-6", if(@wide, do: "max-w-7xl", else: "max-w-3xl")]}>
      {render_slot(@inner_block)}
    </main>
    <footer class="mx-auto max-w-7xl px-4 pb-8 pt-4 text-xs opacity-60 sm:px-6">
      <div class="flex flex-wrap gap-x-4 gap-y-1">
        <span>{gettext("Not affiliated with Kick.")}</span>
        <.link navigate={~p"/about/methodology"}>{gettext("Methodology")}</.link>
        <.link navigate={~p"/about/privacy"}>{gettext("Privacy")}</.link>
        <.link navigate={~p"/about/removal"}>{gettext("Removal requests")}</.link>
      </div>
    </footer>
    <.flash_group flash={@flash} />
    """
  end

  @doc "The admin interface's layout, with its navigation."
  attr :flash, :map, required: true
  attr :current_admin, :map, required: true
  attr :active, :atom, default: nil
  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <header class="border-b border-base-300 bg-base-200">
      <nav class="mx-auto flex max-w-7xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 sm:px-6">
        <.link navigate={~p"/admin"} class="font-semibold">{site_name()} · {gettext("Admin")}</.link>
        <div class="flex flex-1 flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <.admin_link to={~p"/admin"} active={@active == :health}>{gettext("Health")}</.admin_link>
          <.admin_link to={~p"/admin/channels"} active={@active == :channels}>
            {gettext("Channels")}
          </.admin_link>
          <.admin_link to={~p"/admin/groups"} active={@active == :groups}>
            {gettext("Groups")}
          </.admin_link>
          <.admin_link to={~p"/admin/subscriptions"} active={@active == :subscriptions}>
            {gettext("Subscriptions")}
          </.admin_link>
          <.admin_link to={~p"/admin/dead-letters"} active={@active == :dead_letters}>
            {gettext("Dead letters")}
          </.admin_link>
          <.admin_link to={~p"/admin/data"} active={@active == :data}>{gettext("Data")}</.admin_link>
          <.admin_link to={~p"/admin/privacy"} active={@active == :privacy}>
            {gettext("Privacy")}
          </.admin_link>
          <.admin_link to={~p"/admin/settings"} active={@active == :settings}>
            {gettext("Settings")}
          </.admin_link>
          <.admin_link to={~p"/admin/audit"} active={@active == :audit}>
            {gettext("Audit log")}
          </.admin_link>
          <.admin_link to={~p"/admin/admins"} active={@active == :admins}>
            {gettext("Admins")}
          </.admin_link>
          <a href={~p"/admin/errors"} class="opacity-70 hover:opacity-100">
            {gettext("Errors")}
          </a>
          <a href={~p"/admin/dashboard"} class="opacity-70 hover:opacity-100">
            {gettext("Dashboard")}
          </a>
        </div>
        <div class="flex items-center gap-3 text-sm">
          <.link navigate={~p"/admin/account"} class="opacity-70 hover:opacity-100">
            {@current_admin.email}
          </.link>
          <.link href={~p"/admin/logout"} method="delete" class="btn btn-ghost btn-xs">
            {gettext("Log out")}
          </.link>
          <.theme_toggle />
        </div>
      </nav>
    </header>
    <main class="mx-auto max-w-7xl px-4 py-6 sm:px-6">
      {render_slot(@inner_block)}
    </main>
    <.flash_group flash={@flash} />
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp admin_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "rounded px-2 py-1",
        if(@active, do: "bg-base-300 font-medium", else: "opacity-70 hover:opacity-100")
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc "A plain centered page (login, invitations)."
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def bare(assigns) do
    ~H"""
    <main class="px-4 py-16">
      {render_slot(@inner_block)}
    </main>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
