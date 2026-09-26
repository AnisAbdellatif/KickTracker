defmodule KickTrackerWeb.AdminComponents do
  @moduledoc """
  The admin pages' building blocks (project.md §13.8), so every tab has the
  same shape: a page header with its actions, cards (`panel`), stat tiles,
  status pills, empty states, a search box and icon buttons. Built on the
  site's surfaces and tokens (`card-surface`, `inset-well`, `icon-tile`).
  """

  use Phoenix.Component
  use Gettext, backend: KickTrackerWeb.Gettext

  import KickTrackerWeb.CoreComponents, only: [icon: 1]

  @doc "A page's title, what it is for, and its main actions."
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="mb-6 flex flex-wrap items-start justify-between gap-4">
      <div class="flex min-w-0 items-start gap-3">
        <span :if={@icon} class="icon-tile mt-0.5 hidden sm:inline-grid">
          <.icon name={@icon} class="size-5" />
        </span>
        <div class="min-w-0">
          <h1 class="text-xl font-semibold tracking-tight">{@title}</h1>
          <p :if={@subtitle != []} class="text-muted mt-1 max-w-3xl text-sm">
            {render_slot(@subtitle)}
          </p>
        </div>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  A card with an optional title, description and actions. `flush` drops
  the body's padding, for a table that runs to the card's edges.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :icon, :string, default: nil
  attr :flush, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["card-surface min-w-0", @class]} {@rest}>
      <header
        :if={@title || @actions != []}
        class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3"
      >
        <div class="flex min-w-0 items-center gap-2">
          <.icon :if={@icon} name={@icon} class="text-muted size-4.5 shrink-0" />
          <div class="min-w-0">
            <h2 :if={@title} class="font-semibold">{@title}</h2>
            <p :if={@subtitle != []} class="text-muted text-xs">{render_slot(@subtitle)}</p>
          </div>
        </div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </header>
      <div class={[!@flush && "p-4"]}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "A figure on its own: an icon, a label and a value, toned by state."
  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :atom, default: :neutral, values: [:neutral, :ok, :warn, :error]
  slot :inner_block, required: true
  slot :hint

  def stat_tile(assigns) do
    ~H"""
    <div id={@id} class={["card-surface stat-tile flex items-center gap-3 p-4", "tone-#{@tone}"]}>
      <span class="icon-tile"><.icon name={@icon} class="size-5" /></span>
      <div class="min-w-0">
        <p class="text-muted text-xs">{@label}</p>
        <p class="text-lg font-semibold tabular-nums">{render_slot(@inner_block)}</p>
        <p :if={@hint != []} class="text-muted truncate text-xs">{render_slot(@hint)}</p>
      </div>
    </div>
    """
  end

  @doc "A state in a word, with a dot in its colour."
  attr :tone, :atom, default: :neutral, values: [:neutral, :ok, :warn, :error, :info]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def status_pill(assigns) do
    ~H"""
    <span class={["status-pill", "tone-#{@tone}", @class]}>
      <span class="status-dot" aria-hidden="true"></span>{render_slot(@inner_block)}
    </span>
    """
  end

  @doc "What a list shows when it is empty, and what to do about it."
  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col items-center gap-2 px-4 py-10 text-center", @class]}>
      <span class="icon-tile"><.icon name={@icon} class="size-5" /></span>
      <p class="font-medium">{@title}</p>
      <p :if={@inner_block != []} class="text-muted max-w-md text-sm">{render_slot(@inner_block)}</p>
      <div :if={@actions != []} class="mt-2 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc "A search box that sends `event` with `%{\"q\" => text}` as the admin types."
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: nil
  attr :class, :any, default: "w-full sm:w-64"

  def search_field(assigns) do
    ~H"""
    <form id={@id} phx-change={@event} phx-submit={@event} class={@class} role="search">
      <label class="input input-sm w-full">
        <.icon name="hero-magnifying-glass" class="text-muted size-4" />
        <input
          type="search"
          name="q"
          value={@value}
          placeholder={@placeholder || gettext("Search")}
          phx-debounce="150"
          autocomplete="off"
        />
      </label>
    </form>
    """
  end

  @doc "An action shown as its icon, named by its tooltip and for screen readers."
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :atom, default: :neutral, values: [:neutral, :danger, :primary]
  attr :rest, :global, include: ~w(type disabled form name value)

  def icon_button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "btn btn-ghost btn-sm btn-square",
        @tone == :danger && "text-error",
        @tone == :primary && "text-primary"
      ]}
      title={@label}
      aria-label={@label}
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end
end
