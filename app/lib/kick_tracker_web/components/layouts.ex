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

  @doc """
  The admin interface's layout: a sidebar of grouped sections (always
  shown on wide screens, a drawer opened from the top bar on narrow ones),
  with the admin's account, the theme and logging out at its foot. No
  script: the drawer is daisyUI's checkbox, closed again by navigating.
  """
  attr :flash, :map, required: true
  attr :current_admin, :map, required: true
  attr :active, :atom, default: nil
  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="admin-nav" type="checkbox" class="drawer-toggle" aria-label={gettext("Menu")} />
      <div class="drawer-content flex min-h-dvh flex-col">
        <header class="sticky top-0 z-30 flex items-center gap-2 border-b border-base-300 bg-base-100/90 px-3 py-2 backdrop-blur lg:hidden">
          <label
            for="admin-nav"
            class="btn btn-ghost btn-sm btn-square"
            aria-label={gettext("Open the menu")}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </label>
          <.link navigate={~p"/admin"} class="flex items-center gap-2 font-semibold">
            <.brand_mark />{site_name()}
          </.link>
          <span class="badge badge-sm badge-neutral ms-auto">{gettext("Admin")}</span>
        </header>
        <main class="mx-auto w-full max-w-7xl flex-1 px-4 py-6 sm:px-8 sm:py-8">
          {render_slot(@inner_block)}
        </main>
      </div>
      <div class="drawer-side z-40">
        <label for="admin-nav" class="drawer-overlay" aria-label={gettext("Close the menu")}></label>
        <aside class="admin-sidebar flex min-h-full w-64 flex-col border-e border-base-300 bg-base-100">
          <.link navigate={~p"/admin"} class="flex items-center gap-2 px-5 pt-5 pb-4 font-semibold">
            <.brand_mark />{site_name()}
            <span class="badge badge-sm badge-neutral">{gettext("Admin")}</span>
          </.link>
          <nav class="flex-1 space-y-5 overflow-y-auto px-3 pb-4" aria-label={gettext("Admin")}>
            <.admin_section :for={{title, items} <- admin_sections()} title={title}>
              <.admin_link
                :for={{key, icon, label, path, kind} <- items}
                to={path}
                icon={icon}
                active={@active == key}
                external={kind == :external}
              >
                {label}
              </.admin_link>
            </.admin_section>
          </nav>
          <div class="border-t border-base-300 p-3">
            <.link
              navigate={~p"/admin/account"}
              class={[
                "admin-nav-item",
                @active == :account && "is-active"
              ]}
              title={gettext("Your account")}
            >
              <.avatar name={@current_admin.email} class="size-7 text-xs" />
              <span class="min-w-0 flex-1 truncate">{@current_admin.email}</span>
            </.link>
            <div class="mt-2 flex items-center justify-between gap-2 px-1">
              <.theme_toggle />
              <.link href={~p"/admin/logout"} method="delete" class="btn btn-ghost btn-sm gap-1">
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />{gettext("Log out")}
              </.link>
            </div>
          </div>
        </aside>
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  # The sidebar's sections: {key, icon, label, path, :live | :external}.
  defp admin_sections do
    [
      {gettext("Monitor"),
       [
         {:health, "hero-heart", gettext("Health"), ~p"/admin", :live},
         {:anomalies, "hero-exclamation-triangle", gettext("Anomalies"), ~p"/admin/anomalies",
          :live},
         {:audit, "hero-clipboard-document-list", gettext("Audit log"), ~p"/admin/audit", :live},
         {:errors, "hero-bug-ant", gettext("Errors"), ~p"/admin/errors", :external},
         {:dashboard, "hero-chart-bar-square", gettext("Dashboard"), ~p"/admin/dashboard",
          :external}
       ]},
      {gettext("Channels"),
       [
         {:channels, "hero-tv", gettext("Channels"), ~p"/admin/channels", :live},
         {:groups, "hero-rectangle-group", gettext("Groups"), ~p"/admin/groups", :live},
         {:subscriptions, "hero-bell-alert", gettext("Subscriptions"), ~p"/admin/subscriptions",
          :live}
       ]},
      {gettext("Data"),
       [
         {:data, "hero-wrench-screwdriver", gettext("Corrections"), ~p"/admin/data", :live},
         {:chat_log, "hero-chat-bubble-left-right", gettext("Chat log"), ~p"/admin/chat-log",
          :live},
         {:transfer, "hero-arrows-right-left", gettext("Export / import"), ~p"/admin/transfer",
          :live},
         {:dead_letters, "hero-inbox-stack", gettext("Dead letters"), ~p"/admin/dead-letters",
          :live}
       ]},
      {gettext("People"),
       [
         {:privacy, "hero-shield-check", gettext("Privacy requests"), ~p"/admin/privacy", :live},
         {:admins, "hero-user-group", gettext("Admins"), ~p"/admin/admins", :live}
       ]},
      {gettext("Site"),
       [
         {:settings, "hero-cog-6-tooth", gettext("Settings"), ~p"/admin/settings", :live},
         {:site, "hero-globe-alt", gettext("Public site"), ~p"/", :external}
       ]}
    ]
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp admin_section(assigns) do
    ~H"""
    <div>
      <p class="admin-nav-title">{@title}</p>
      <div class="space-y-0.5">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :external, :boolean, default: false
  slot :inner_block, required: true

  defp admin_link(%{external: true} = assigns) do
    ~H"""
    <a href={@to} class="admin-nav-item">
      <.icon name={@icon} class="size-4.5 shrink-0" />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <.icon name="hero-arrow-up-right" class="size-3 opacity-50" />
    </a>
    """
  end

  defp admin_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={["admin-nav-item", @active && "is-active"]}
      aria-current={@active && "page"}
    >
      <.icon name={@icon} class="size-4.5 shrink-0" />
      <span class="flex-1">{render_slot(@inner_block)}</span>
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
