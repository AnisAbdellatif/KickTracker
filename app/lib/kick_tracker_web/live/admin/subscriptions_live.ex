defmodule KickTrackerWeb.Admin.SubscriptionsLive do
  @moduledoc """
  Kick's webhook subscriptions against what they should be (project.md
  §13.8): per active channel and event type, and the extra ones a sync
  would remove. "Resync" queues `SubscriptionSync` on the collector.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Channels}
  alias KickTracker.Kick.API
  alias KickTracker.Workers.SubscriptionSync

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Subscriptions"), q: "", incomplete?: false)
     |> load()}
  end

  defp load(socket) do
    channels = Channels.list_active()
    wanted = SubscriptionSync.events()

    case API.subscriptions() do
      {:ok, subs} ->
        have = MapSet.new(subs, &{&1["broadcaster_user_id"], &1["event"]})
        {create, delete} = SubscriptionSync.plan(channels, subs)

        assign(socket,
          error: nil,
          channels: channels,
          wanted: wanted,
          have: have,
          missing: Enum.sum_by(create, fn {_, events} -> length(events) end),
          extra: length(delete),
          total: length(subs)
        )

      {:error, reason} ->
        assign(socket,
          error: inspect(reason),
          channels: channels,
          wanted: wanted,
          have: MapSet.new(),
          missing: nil,
          extra: nil,
          total: nil
        )
    end
  catch
    :exit, reason ->
      assign(socket,
        error: inspect(reason),
        channels: [],
        wanted: [],
        have: MapSet.new(),
        missing: nil,
        extra: nil,
        total: nil
      )
  end

  @impl true
  def handle_event("resync", _params, socket) do
    {:ok, _} = SubscriptionSync.enqueue()
    Audit.log(socket.assigns.current_admin, "subscriptions.resync")

    {:noreply,
     put_flash(socket, :info, gettext("Resync queued; the collector runs it within seconds."))}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, q: q)}

  def handle_event("incomplete", _params, socket),
    do: {:noreply, assign(socket, incomplete?: not socket.assigns.incomplete?)}

  @impl true
  def render(assigns) do
    rows =
      for c <- assigns.channels do
        n = Enum.count(assigns.wanted, &MapSet.member?(assigns.have, {c.kick_user_id, &1}))
        %{channel: c, n: n, complete?: n == length(assigns.wanted)}
      end

    q = String.downcase(String.trim(assigns.q))

    shown =
      Enum.filter(rows, fn r ->
        (q == "" or String.contains?(String.downcase(r.channel.slug), q)) and
          (not assigns.incomplete? or not r.complete?)
      end)

    assigns =
      assign(assigns, rows: rows, shown: shown, complete: Enum.count(rows, & &1.complete?))

    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:subscriptions}>
      <.page_header title={gettext("Webhook subscriptions")} icon="hero-bell-alert">
        <:subtitle>
          {gettext(
            "Which events Kick sends us for each tracked channel. Where deliveries go is set once in the Kick app's settings; a sync every 15 minutes adds what is missing and removes the rest."
          )}
        </:subtitle>
        <:actions>
          <button id="refresh" phx-click="refresh" class="btn btn-sm btn-ghost gap-1">
            <.icon name="hero-arrow-path" class="size-4" />{gettext("Refresh")}
          </button>
          <button id="resync" phx-click="resync" class="btn btn-sm btn-primary gap-1">
            <.icon name="hero-arrows-right-left" class="size-4" />{gettext("Resync now")}
          </button>
        </:actions>
      </.page_header>

      <.panel :if={@error} id="subscriptions-error" class="border-error/50">
        <div class="flex items-start gap-3">
          <span class="icon-tile text-error"><.icon name="hero-exclamation-triangle" class="size-5" /></span>
          <div class="min-w-0">
            <p class="font-medium">
              {gettext("Kick didn't answer, so the subscriptions can't be compared.")}
            </p>
            <p class="text-muted mt-1 text-sm">
              {gettext("Nothing is changed meanwhile; refresh to try again.")}
            </p>
            <details class="mt-2 text-xs">
              <summary class="text-muted cursor-pointer">{gettext("Details")}</summary>
              <pre class="inset-well mt-2 overflow-x-auto p-2">{@error}</pre>
            </details>
          </div>
        </div>
      </.panel>

      <div :if={@total} id="subscriptions-summary" class="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat_tile icon="hero-cloud" label={gettext("At Kick")}>{@total}</.stat_tile>
        <.stat_tile
          icon="hero-plus-circle"
          label={gettext("Missing")}
          tone={if @missing > 0, do: :error, else: :ok}
        >
          {@missing}
        </.stat_tile>
        <.stat_tile
          icon="hero-minus-circle"
          label={gettext("To remove")}
          tone={if @extra > 0, do: :warn, else: :ok}
        >
          {@extra}
        </.stat_tile>
        <.stat_tile
          icon="hero-check-circle"
          label={gettext("Channels complete")}
          tone={if @complete == length(@rows), do: :ok, else: :warn}
        >
          {@complete}<span class="text-muted text-sm font-normal"> / {length(@rows)}</span>
        </.stat_tile>
      </div>

      <.panel
        :if={!@error}
        id="subscriptions-panel"
        title={gettext("By channel")}
        icon="hero-table-cells"
        flush
      >
        <:actions>
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input
              id="subscriptions-incomplete"
              type="checkbox"
              class="toggle toggle-sm toggle-primary"
              checked={@incomplete?}
              phx-click="incomplete"
            />
            {gettext("Incomplete only")}
          </label>
          <.search_field
            id="subscriptions-search"
            event="search"
            value={@q}
            placeholder={gettext("Search channels")}
          />
        </:actions>
        <div class="scroll-panel max-h-[70vh] overflow-auto">
          <table id="subscriptions" class="table table-sm table-pin-rows table-pin-cols">
            <thead>
              <tr>
                <th>{gettext("Channel")}</th>
                <td :for={e <- @wanted} class="text-center text-xs font-semibold" title={e}>
                  {type_label(e)}
                </td>
                <td class="text-end text-xs font-semibold">{gettext("Total")}</td>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- @shown} id={"subscriptions-#{r.channel.id}"}>
                <th class="bg-base-100 font-medium">{r.channel.slug}</th>
                <td :for={e <- @wanted} class="text-center">
                  <%= if MapSet.member?(@have, {r.channel.kick_user_id, e}) do %>
                    <.icon name="hero-check-circle-mini" class="size-5 text-success" />
                    <span class="sr-only">{gettext("subscribed")}</span>
                  <% else %>
                    <.icon name="hero-x-circle-mini" class="size-5 text-error" />
                    <span class="sr-only">{gettext("missing")}</span>
                  <% end %>
                </td>
                <td class="text-end">
                  <.status_pill tone={if r.complete?, do: :ok, else: :error}>
                    {r.n}/{length(@wanted)}
                  </.status_pill>
                </td>
              </tr>
            </tbody>
          </table>
          <.empty_state
            :if={@rows == []}
            icon="hero-tv"
            title={gettext("No channel is being tracked.")}
          />
          <.empty_state
            :if={@rows != [] and @shown == []}
            icon="hero-check-circle"
            title={
              if @incomplete?,
                do: gettext("Every channel has all its subscriptions."),
                else: gettext("No channel matches.")
            }
          />
        </div>
      </.panel>
    </Layouts.admin>
    """
  end

  # The event types, short enough for a column (the full name on hover).
  defp type_label("livestream.status.updated"), do: gettext("Live status")
  defp type_label("livestream.metadata.updated"), do: gettext("Title, category")
  defp type_label("channel.followed"), do: gettext("Follows")
  defp type_label("channel.subscription.new"), do: gettext("New subs")
  defp type_label("channel.subscription.renewal"), do: gettext("Renewals")
  defp type_label("channel.subscription.gifts"), do: gettext("Gifts")
  defp type_label("kicks.gifted"), do: gettext("Kicks")
  defp type_label(other), do: other
end
