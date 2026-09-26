defmodule KickTrackerWeb.Admin.ChannelPicker do
  @moduledoc """
  Picks one channel from a list that may be long (admin pages): a button
  showing the current one, opening a panel with a search box and the
  channels that match, scrolling. Typing filters, Enter takes the first
  match, Escape or a click elsewhere closes it.

  The parent is told with `{KickTrackerWeb.Admin.ChannelPicker, id, channel_id}`
  (a message to its own process) and decides what a pick does, usually a
  patch to its own URL.
  """

  use KickTrackerWeb, :live_component

  @impl true
  def mount(socket), do: {:ok, assign(socket, open?: false, q: "")}

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, Map.take(assigns, [:id, :channels, :selected, :label]))}
  end

  @impl true
  def handle_event("toggle", _params, socket),
    do: {:noreply, assign(socket, open?: not socket.assigns.open?, q: "")}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open?: false)}

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, q: q)}

  def handle_event("key", %{"key" => "Escape"}, socket),
    do: {:noreply, assign(socket, open?: false)}

  # Enter in the search box submits its form: the first match is taken.
  def handle_event("submit", params, socket) do
    case matches(socket.assigns.channels, params["q"] || socket.assigns.q) do
      [first | _] -> pick(socket, first.id)
      [] -> {:noreply, socket}
    end
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  def handle_event("pick", %{"id" => id}, socket), do: pick(socket, String.to_integer(id))

  defp pick(socket, id) do
    send(self(), {__MODULE__, socket.assigns.id, id})
    {:noreply, assign(socket, open?: false, q: "")}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, shown: matches(assigns.channels, assigns.q))

    ~H"""
    <div id={@id} class="relative" phx-click-away={@open? && "close"} phx-target={@myself}>
      <button
        id={"#{@id}-button"}
        type="button"
        phx-click="toggle"
        phx-target={@myself}
        aria-haspopup="listbox"
        aria-expanded={to_string(@open?)}
        class="btn btn-sm btn-ghost w-64 justify-start gap-2 border border-base-300 font-normal"
      >
        <%= if @selected do %>
          <.avatar name={@selected.slug} channel_id={@selected.id} class="size-5 text-[0.6rem]" />
          <span class="min-w-0 flex-1 truncate text-start">{@selected.slug}</span>
        <% else %>
          <span class="text-muted flex-1 text-start">{@label || gettext("Choose a channel")}</span>
        <% end %>
        <.icon name="hero-chevrons-up-down" class="text-muted size-4" />
      </button>

      <div
        :if={@open?}
        id={"#{@id}-panel"}
        class="card-surface popover-panel absolute end-0 z-30 mt-2 w-72 p-2"
      >
        <form id={"#{@id}-search"} phx-change="search" phx-submit="submit" phx-target={@myself}>
          <label class="input input-sm w-full">
            <.icon name="hero-magnifying-glass" class="text-muted size-4" />
            <input
              type="search"
              name="q"
              value={@q}
              placeholder={gettext("Search channels")}
              autocomplete="off"
              phx-debounce="100"
              phx-keydown="key"
              phx-target={@myself}
              phx-mounted={JS.focus()}
              aria-controls={"#{@id}-options"}
            />
          </label>
        </form>
        <ul id={"#{@id}-options"} role="listbox" class="scroll-panel mt-2 max-h-72 overflow-y-auto">
          <li :for={c <- @shown}>
            <button
              id={"#{@id}-option-#{c.id}"}
              type="button"
              role="option"
              aria-selected={to_string(@selected && @selected.id == c.id)}
              phx-click="pick"
              phx-value-id={c.id}
              phx-target={@myself}
              class={["picker-option", @selected && @selected.id == c.id && "text-primary"]}
            >
              <.avatar name={c.slug} channel_id={c.id} class="size-6 text-[0.65rem]" />
              <span class="min-w-0 flex-1 truncate">{c.slug}</span>
              <span :if={!c.active} class="text-muted text-xs">{gettext("paused")}</span>
              <.icon :if={@selected && @selected.id == c.id} name="hero-check" class="size-4" />
            </button>
          </li>
        </ul>
        <p :if={@shown == []} class="text-muted px-2 py-4 text-center text-xs">
          {gettext("No channel matches.")}
        </p>
      </div>
    </div>
    """
  end

  # Channels whose slug contains the query, those starting with it first.
  defp matches(channels, q) do
    q = String.downcase(String.trim(q || ""))

    if q == "" do
      channels
    else
      channels
      |> Enum.filter(&String.contains?(String.downcase(&1.slug), q))
      |> Enum.sort_by(&{not String.starts_with?(String.downcase(&1.slug), q), &1.slug})
    end
  end
end
