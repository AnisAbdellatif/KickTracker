defmodule KickTrackerWeb.Admin.ChannelsLive do
  @moduledoc """
  Tracked channels (project.md §13.8): add by slug (looked up on Kick and
  previewed first), pause and resume, set the timezone. Every change is
  a row plus a `"channels:changed"` broadcast; the collector does the rest.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Channels}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Channels"), preview: nil, editing: nil, deleting: nil)
     |> assign(q: "", show: "all")
     |> assign(lookup: to_form(%{"slug" => ""}, as: "lookup"))
     |> assign(timezones: Channels.timezones())
     |> load()}
  end

  defp load(socket),
    do: assign(socket, channels: Channels.list_all(), live: Channels.open_streams())

  @impl true
  def handle_event("lookup", %{"lookup" => %{"slug" => slug}}, socket) do
    case Channels.preview(slug) do
      {:ok, preview} ->
        {:noreply,
         assign(socket,
           preview: preview,
           confirm: to_form(%{"timezone" => preview.timezone}, as: "confirm")
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(preview: nil)
         |> put_flash(:error, gettext("No channel with that slug on Kick."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(preview: nil)
         |> put_flash(:error, gettext("Kick didn't answer: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, preview: nil)}

  def handle_event("confirm", %{"confirm" => %{"timezone" => tz}}, socket) do
    %{preview: preview, current_admin: admin} = socket.assigns

    case Channels.add(preview.slug, timezone: tz) do
      {:ok, channel} ->
        Audit.log(admin, "channel.add", channel.slug, %{
          "channel_id" => channel.id,
          "timezone" => channel.timezone
        })

        {:noreply,
         socket
         |> assign(preview: nil)
         |> put_flash(:info, gettext("Now tracking %{slug}.", slug: channel.slug))
         |> load()}

      {:error, :bad_timezone} ->
        {:noreply, put_flash(socket, :error, gettext("Unknown timezone."))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not add: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    channel = Channels.get!(String.to_integer(id))
    {:ok, channel} = Channels.set_active(channel, not channel.active)

    Audit.log(
      socket.assigns.current_admin,
      if(channel.active, do: "channel.resume", else: "channel.pause"),
      channel.slug,
      %{"channel_id" => channel.id}
    )

    {:noreply, load(socket)}
  end

  # How much of the channel the public site shows (§13.2): a removal
  # request is answered here too, at the level the admin chooses.
  def handle_event("set_visibility", %{"channel_id" => id, "visibility" => level}, socket)
      when level in ~w(public live_only hidden) do
    channel = Channels.get!(String.to_integer(id))
    level = String.to_existing_atom(level)

    if level != channel.visibility do
      {:ok, _} = Channels.set_visibility(channel, level)

      Audit.log(socket.assigns.current_admin, "channel.visibility", channel.slug, %{
        "from" => Atom.to_string(channel.visibility),
        "to" => Atom.to_string(level)
      })
    end

    {:noreply, load(socket)}
  end

  def handle_event("ask_delete", %{"id" => id}, socket),
    do: {:noreply, assign(socket, deleting: String.to_integer(id))}

  def handle_event("cancel_delete", _, socket), do: {:noreply, assign(socket, deleting: nil)}

  def handle_event("delete", %{"channel_id" => id, "slug" => typed}, socket) do
    channel = Channels.get!(String.to_integer(id))

    if typed == channel.slug do
      {:ok, _} =
        KickTracker.Workers.DeleteChannel.new(%{"channel_id" => channel.id}) |> Oban.insert()

      Audit.log(socket.assigns.current_admin, "channel.delete_data", channel.slug, %{
        "channel_id" => channel.id
      })

      {:noreply,
       socket
       |> assign(deleting: nil)
       |> put_flash(:info, gettext("Deleting %{slug} and all its data.", slug: channel.slug))
       |> load()}
    else
      {:noreply, put_flash(socket, :error, gettext("Type the slug exactly to confirm."))}
    end
  end

  def handle_event("edit_tz", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing: String.to_integer(id))}

  def handle_event("save_tz", %{"channel_id" => id, "timezone" => tz}, socket) do
    channel = Channels.get!(String.to_integer(id))

    case Channels.set_timezone(channel, tz) do
      {:ok, updated} ->
        Audit.log(socket.assigns.current_admin, "channel.timezone", updated.slug, %{
          "from" => channel.timezone,
          "to" => updated.timezone
        })

        {:noreply, socket |> assign(editing: nil) |> load()}

      {:error, :bad_timezone} ->
        {:noreply, put_flash(socket, :error, gettext("Unknown timezone."))}
    end
  end

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, q: q)}

  def handle_event("show", %{"show" => show}, socket)
      when show in ~w(all tracking paused live_only hidden live),
      do: {:noreply, assign(socket, show: show)}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown: shown(assigns),
        counts: %{
          "all" => length(assigns.channels),
          "tracking" => Enum.count(assigns.channels, & &1.active),
          "paused" => Enum.count(assigns.channels, &(not &1.active)),
          "live_only" => Enum.count(assigns.channels, &(&1.visibility == :live_only)),
          "hidden" => Enum.count(assigns.channels, &(&1.visibility == :hidden)),
          "live" => map_size(assigns.live)
        },
        deleting_channel:
          assigns.deleting && Enum.find(assigns.channels, &(&1.id == assigns.deleting))
      )

    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:channels}>
      <.page_header title={gettext("Channels")} icon="hero-tv">
        <:subtitle>
          {gettext(
            "The channels being tracked. Pausing stops collection and keeps everything already collected. \"Live only\" shows a channel on the public site only while it is live, with its viewers and active chatters now; \"Hidden\" removes it from the public site and regular API keys."
          )}
        </:subtitle>
      </.page_header>

      <.panel id="add-channel" title={gettext("Add a channel")} icon="hero-plus-circle" class="mb-6">
        <.form
          for={@lookup}
          id="lookup-form"
          phx-submit="lookup"
          class="flex flex-wrap items-end gap-2"
        >
          <div class="min-w-56 max-w-sm flex-1">
            <.input
              field={@lookup[:slug]}
              label={gettext("Kick slug")}
              placeholder="somestreamer"
              required
            />
          </div>
          <.button class="btn mb-2 gap-1" phx-disable-with={gettext("Looking up…")}>
            <.icon name="hero-magnifying-glass" class="size-4" />{gettext("Look up")}
          </.button>
        </.form>

        <div :if={@preview} id="channel-preview" class="inset-well mt-4 grid gap-6 p-4 md:grid-cols-2">
          <div class="flex gap-3">
            <.avatar name={@preview.slug} class="size-12 text-lg" />
            <div class="min-w-0">
              <p class="flex flex-wrap items-center gap-2 font-semibold">
                {@preview.slug}
                <span :if={@preview.live?} class="live-pill">{gettext("live")}</span>
              </p>
              <p class="text-muted text-sm">
                <%= if @preview.live? do %>
                  {gettext("%{n} viewers", n: @preview.viewers)}
                <% else %>
                  {gettext("offline")}
                <% end %>
                · {@preview.category || "–"}
              </p>
              <p class="mt-1 break-words text-sm">{@preview.title || "–"}</p>
              <p class="text-muted mt-1 text-xs">
                {gettext("Kick user id")} {@preview.kick_user_id} · {gettext("Language")} {@preview.language ||
                  "–"}
              </p>
            </div>
          </div>
          <div>
            <p :if={@preview.existing} class="mb-2 flex items-center gap-1 text-sm text-warning">
              <.icon name="hero-information-circle" class="size-4" />
              <%= if @preview.existing.active do %>
                {gettext("Already tracked.")}
              <% else %>
                {gettext("Tracked before and paused: confirming resumes it with its history.")}
              <% end %>
            </p>
            <.form for={@confirm} id="confirm-form" phx-submit="confirm" class="space-y-2">
              <.input
                field={@confirm[:timezone]}
                label={gettext("Timezone (for daily and weekday figures)")}
                list="timezones"
                required
              />
              <div class="flex gap-2">
                <.button
                  class="btn btn-primary"
                  disabled={@preview.existing && @preview.existing.active}
                >
                  {gettext("Track this channel")}
                </.button>
                <button type="button" phx-click="cancel" class="btn btn-ghost">{gettext("Cancel")}</button>
              </div>
            </.form>
          </div>
        </div>
      </.panel>

      <datalist id="timezones">
        <option :for={tz <- @timezones} value={tz} />
      </datalist>

      <.panel id="channels-panel" title={gettext("Tracked channels")} icon="hero-tv" flush>
        <:actions>
          <nav class="segmented" aria-label={gettext("Show")}>
            <button
              :for={
                {key, label} <- [
                  {"all", gettext("All")},
                  {"tracking", gettext("Tracking")},
                  {"paused", gettext("Paused")},
                  {"live_only", gettext("Live only")},
                  {"hidden", gettext("Hidden")},
                  {"live", gettext("Live")}
                ]
              }
              id={"channels-show-#{key}"}
              type="button"
              phx-click="show"
              phx-value-show={key}
              class={["segmented-item", @show == key && "is-active"]}
            >
              {label} · {@counts[key]}
            </button>
          </nav>
          <.search_field
            id="channels-search"
            event="search"
            value={@q}
            placeholder={gettext("Search channels")}
          />
        </:actions>
        <div class="scroll-panel max-h-[70vh] overflow-auto">
          <table id="channels" class="table table-sm table-pin-rows">
            <thead>
              <tr>
                <th>{gettext("Channel")}</th>
                <th>{gettext("Status")}</th>
                <th>{gettext("Timezone")}</th>
                <th>{gettext("Tracked since")}</th>
                <th class="text-end">{gettext("Actions")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @shown} id={"channel-#{c.id}"} class={!c.active && "opacity-70"}>
                <td>
                  <div class="flex items-center gap-2.5">
                    <.avatar name={c.slug} channel_id={c.id} class="size-8 text-sm" />
                    <div class="min-w-0">
                      <p class="flex items-center gap-2 font-medium">
                        <span class="truncate">{c.slug}</span>
                        <span :if={Map.has_key?(@live, c.id)} class="live-pill">{gettext("live")}</span>
                      </p>
                      <p class="text-muted text-xs">
                        {gettext("user")} {c.kick_user_id} · {gettext("chatroom")} {c.chatroom_id ||
                          "?"}
                      </p>
                    </div>
                  </div>
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <.status_pill tone={if c.active, do: :ok, else: :neutral}>
                      {if c.active, do: gettext("tracking"), else: gettext("paused")}
                    </.status_pill>
                    <.status_pill :if={c.visibility == :live_only} tone={:info}>
                      {gettext("live only")}
                    </.status_pill>
                    <.status_pill :if={c.visibility == :hidden} tone={:warn}>
                      {gettext("hidden")}
                    </.status_pill>
                    <.status_pill :if={c.chat_log} tone={:info}>
                      {gettext("chat logged")}
                    </.status_pill>
                  </div>
                </td>
                <td>
                  <%= if @editing == c.id do %>
                    <form id={"tz-form-#{c.id}"} phx-submit="save_tz" class="flex gap-1">
                      <input type="hidden" name="channel_id" value={c.id} />
                      <input
                        name="timezone"
                        value={c.timezone}
                        list="timezones"
                        class="input input-xs w-44"
                        phx-mounted={Phoenix.LiveView.JS.focus()}
                      />
                      <button class="btn btn-xs btn-primary">{gettext("Save")}</button>
                    </form>
                  <% else %>
                    <button
                      phx-click="edit_tz"
                      phx-value-id={c.id}
                      class="group inline-flex items-center gap-1 text-sm hover:text-primary"
                      title={gettext("Change the timezone")}
                    >
                      {c.timezone}
                      <.icon
                        name="hero-pencil-square"
                        class="size-3.5 opacity-0 group-hover:opacity-70"
                      />
                    </button>
                  <% end %>
                </td>
                <td class="text-sm tabular-nums">{Calendar.strftime(c.tracked_since, "%Y-%m-%d")}</td>
                <td>
                  <div class="flex justify-end gap-0.5">
                    <.link
                      navigate={~p"/c/#{c.slug}"}
                      class="btn btn-ghost btn-sm btn-square"
                      title={gettext("Public page")}
                      aria-label={gettext("Public page")}
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                    </.link>
                    <.icon_button
                      id={"toggle-#{c.id}"}
                      icon={if c.active, do: "hero-pause", else: "hero-play"}
                      label={if c.active, do: gettext("Pause"), else: gettext("Resume")}
                      phx-click="toggle"
                      phx-value-id={c.id}
                      data-confirm={
                        if c.active,
                          do:
                            gettext("Pause tracking %{slug}? Nothing is collected while paused.",
                              slug: c.slug
                            )
                      }
                    />
                    <form id={"visibility-#{c.id}"} phx-change="set_visibility">
                      <input type="hidden" name="channel_id" value={c.id} />
                      <select
                        name="visibility"
                        class="select select-sm w-28"
                        aria-label={gettext("Shown on the public site")}
                        title={gettext("Shown on the public site")}
                      >
                        <option
                          :for={
                            {value, label} <- [
                              {"public", gettext("Public")},
                              {"live_only", gettext("Live only")},
                              {"hidden", gettext("Hidden")}
                            ]
                          }
                          value={value}
                          selected={Atom.to_string(c.visibility) == value}
                        >
                          {label}
                        </option>
                      </select>
                    </form>
                    <.icon_button
                      id={"ask-delete-#{c.id}"}
                      icon="hero-trash"
                      label={gettext("Delete…")}
                      tone={:danger}
                      phx-click="ask_delete"
                      phx-value-id={c.id}
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
          <.empty_state :if={@channels == []} icon="hero-tv" title={gettext("No channels yet.")}>
            {gettext("Add one above by its Kick slug.")}
          </.empty_state>
          <.empty_state
            :if={@channels != [] and @shown == []}
            icon="hero-magnifying-glass"
            title={gettext("No channel matches.")}
          />
        </div>
      </.panel>

      <div
        :if={@deleting_channel}
        id="delete-dialog"
        class="fixed inset-0 z-50 grid place-items-center bg-black/50 p-4"
        role="dialog"
        aria-modal="true"
        phx-window-keydown="cancel_delete"
        phx-key="Escape"
      >
        <form
          id={"delete-#{@deleting_channel.id}"}
          phx-submit="delete"
          phx-click-away="cancel_delete"
          class="card-surface w-full max-w-md space-y-3 p-5"
        >
          <input type="hidden" name="channel_id" value={@deleting_channel.id} />
          <div class="flex items-start gap-3">
            <span class="icon-tile text-error"><.icon name="hero-trash" class="size-5" /></span>
            <div>
              <h2 class="font-semibold">
                {gettext("Delete %{slug} and all its data?", slug: @deleting_channel.slug)}
              </h2>
              <p class="text-muted mt-1 text-sm">
                {gettext(
                  "Stops tracking and deletes every stream, sample, chat count, event and log of the channel, for good. For a removal request; to stop collecting, pause it instead."
                )}
              </p>
            </div>
          </div>
          <label class="block text-sm">
            <span class="text-muted">{gettext("Type %{slug} to confirm", slug: @deleting_channel.slug)}</span>
            <input
              name="slug"
              class="input input-sm mt-1 w-full"
              autocomplete="off"
              phx-mounted={Phoenix.LiveView.JS.focus()}
            />
          </label>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_delete" class="btn btn-sm btn-ghost">{gettext(
              "Cancel"
            )}</button>
            <button class="btn btn-sm btn-error">{gettext("Delete all data")}</button>
          </div>
        </form>
      </div>
    </Layouts.admin>
    """
  end

  defp shown(%{channels: channels, live: live, q: q, show: show}) do
    q = String.downcase(String.trim(q))

    Enum.filter(channels, fn c ->
      (q == "" or String.contains?(String.downcase(c.slug), q)) and
        case show do
          "tracking" -> c.active
          "paused" -> not c.active
          "live_only" -> c.visibility == :live_only
          "hidden" -> c.visibility == :hidden
          "live" -> Map.has_key?(live, c.id)
          _ -> true
        end
    end)
  end
end
