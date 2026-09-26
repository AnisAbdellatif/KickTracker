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
  attr :active, :atom, default: nil, doc: "the nav item to mark current: :live, :compare, :about"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/90 backdrop-blur">
      <nav class="mx-auto flex max-w-7xl items-center gap-3 px-4 py-2.5 sm:gap-6 sm:px-6">
        <.link navigate={~p"/"} class="flex shrink-0 items-center gap-2 font-semibold tracking-tight">
          <.brand_mark />
          <span class="hidden sm:inline">{site_name()}</span>
        </.link>
        <div class="no-scrollbar flex min-w-0 flex-1 items-center gap-1 overflow-x-auto text-sm">
          <.nav_link to={~p"/"} active={@active == :live}>{gettext("Live")}</.nav_link>
          <.nav_link to={~p"/compare"} active={@active == :compare}>{gettext("Compare")}</.nav_link>
          <.nav_link to={~p"/about/methodology"} active={@active == :about} class="hidden sm:block">
            {gettext("Methodology")}
          </.nav_link>
        </div>
        <form action={~p"/search"} method="get" class="hidden md:block" role="search">
          <label class="input input-sm w-52">
            <.icon name="hero-magnifying-glass-micro" class="size-4 opacity-50" />
            <input
              type="search"
              name="q"
              placeholder={gettext("Find a channel")}
              aria-label={gettext("Find a channel")}
            />
          </label>
        </form>
        <.link
          href={~p"/search"}
          class="btn btn-ghost btn-sm btn-square md:hidden"
          aria-label={gettext("Find a channel")}
        >
          <.icon name="hero-magnifying-glass" class="size-5" />
        </.link>
        <.theme_toggle />
      </nav>
    </header>
    <main class={["mx-auto px-4 py-6 sm:px-6 sm:py-8", if(@wide, do: "max-w-7xl", else: "max-w-3xl")]}>
      {render_slot(@inner_block)}
    </main>
    <footer class="border-t border-base-300">
      <div class="mx-auto flex max-w-7xl flex-wrap items-center gap-x-5 gap-y-2 px-4 py-6 text-xs text-base-content/60 sm:px-6">
        <span class="flex items-center gap-2 font-medium text-base-content/80">
          <.brand_mark class="size-4" />{site_name()}
        </span>
        <span>{gettext("Not affiliated with Kick.")}</span>
        <span class="flex-1"></span>
        <.link navigate={~p"/about/methodology"} class="hover:text-base-content">
          {gettext("Methodology")}
        </.link>
        <.link navigate={~p"/about/privacy"} class="hover:text-base-content">
          {gettext("Privacy")}
        </.link>
        <.link navigate={~p"/about/removal"} class="hover:text-base-content">
          {gettext("Removal requests")}
        </.link>
      </div>
    </footer>
    <.flash_group flash={@flash} />
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      aria-current={@active && "page"}
      class={[
        "shrink-0 rounded-field px-2.5 py-1.5 transition-colors",
        @class,
        if(@active,
          do: "bg-base-200 font-medium text-base-content",
          else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc "The site's mark: three rising bars."
  attr :class, :string, default: "size-6"

  def brand_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={["text-primary", @class]} aria-hidden="true">
      <rect x="2" y="2" width="20" height="20" rx="6" fill="currentColor" />
      <rect x="6.5" y="12" width="2.5" height="6" rx="1.25" fill="white" />
      <rect x="10.75" y="9" width="2.5" height="9" rx="1.25" fill="white" />
      <rect x="15" y="6" width="2.5" height="12" rx="1.25" fill="white" />
    </svg>
    """
  end

  @doc "The admin interface's layout, with its navigation."
  attr :flash, :map, required: true
  attr :current_admin, :map, required: true
  attr :active, :atom, default: nil
  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <header class="border-b border-base-300 bg-base-100">
      <nav class="mx-auto flex max-w-7xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 sm:px-6">
        <.link navigate={~p"/admin"} class="flex items-center gap-2 font-semibold">
          <.brand_mark />{site_name()}
          <span class="badge badge-sm badge-neutral">{gettext("Admin")}</span>
        </.link>
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
          <.admin_link to={~p"/admin/anomalies"} active={@active == :anomalies}>
            {gettext("Anomalies")}
          </.admin_link>
          <.admin_link to={~p"/admin/transfer"} active={@active == :transfer}>
            {gettext("Export / import")}
          </.admin_link>
          <.admin_link to={~p"/admin/chat-log"} active={@active == :chat_log}>
            {gettext("Chat log")}
          </.admin_link>
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
          <a href={~p"/admin/errors"} class="px-2 py-1 text-base-content/70 hover:text-base-content">
            {gettext("Errors")}
          </a>
          <a
            href={~p"/admin/dashboard"}
            class="px-2 py-1 text-base-content/70 hover:text-base-content"
          >
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
        "rounded-field px-2 py-1 transition-colors",
        if(@active,
          do: "bg-base-200 font-medium",
          else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        )
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
        <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
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
        <.icon name="hero-arrow-path" class="ms-1 size-3 motion-safe:animate-spin" />
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
    <div
      id="theme-toggle"
      phx-update="ignore"
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
      role="group"
      aria-label={gettext("Theme")}
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 start-0 [[data-theme=light]_&]:start-1/3 [[data-theme=dark]_&]:start-2/3 [[data-theme-source=system]_&]:!start-0 transition-[inset-inline-start]" />

      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", gettext("System theme")},
            {"light", "hero-sun-micro", gettext("Light theme")},
            {"dark", "hero-moon-micro", gettext("Dark theme")}
          ]
        }
        type="button"
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
        aria-pressed="false"
      >
        <.icon name={icon} class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc "The page's language, from the Gettext locale (`<html lang>`)."
  def html_lang, do: Gettext.get_locale(KickTrackerWeb.Gettext) |> String.replace("_", "-")

  @rtl ~w(ar arc dv fa he ks ku ps sd ug ur yi)

  @doc "The page's direction: right-to-left for languages written that way."
  def html_dir do
    lang = html_lang() |> String.split("-") |> hd()
    if lang in @rtl, do: "rtl", else: "ltr"
  end

  @doc "The page's description, for search results and link previews."
  def description(assigns) do
    assigns[:page_description] ||
      gettext(
        "Viewers, streams, chat and support of Kick channels, tracked over time. Not affiliated with Kick."
      )
  end
end
