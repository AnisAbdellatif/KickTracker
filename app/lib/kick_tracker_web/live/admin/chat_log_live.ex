defmodule KickTrackerWeb.Admin.ChatLogLive do
  @moduledoc """
  Chat logging (project.md §12.8), admin only: turn it on or off per
  channel and set how long each channel's log is kept; read the log by
  channels, users (across channels) and period; export what the filters
  select as CSV; delete a channel's log for a period (the collector runs
  it, see `Workers.ChatLog`).

  Built for many channels: both channel lists are searched on the server
  and scroll inside their panel. The filters live in the URL, so a view
  is reproducible and shareable between admins. Views, exports, deletions
  and setting changes are audited; which users were looked up is not
  written down (as for privacy searches), only that a view was by user.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Channels, ChatLog}
  alias KickTrackerWeb.Admin.ChatLogFilters

  @page 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Chat log"),
       settings_q: "",
       settings_show: "all",
       picker_open?: false,
       picker_q: "",
       custom_open?: false,
       deleting: nil,
       messages: [],
       events: [],
       more?: false
     )
     |> load_channels()}
  end

  defp load_channels(socket) do
    assign(socket,
      channels: Channels.list_all(),
      logged: ChatLog.channels(),
      summary: ChatLog.summary()
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {filters, form} = ChatLogFilters.parse(params)
    tab = if params["tab"] == "events", do: "events", else: "messages"
    viewing? = map_size(filters) > 0

    if viewing? and connected?(socket), do: audit_view(socket, "chat_log.view", filters, tab)

    {:noreply,
     socket
     |> assign(filters: filters, form: form, tab: tab, viewing?: viewing?)
     |> assign(
       custom_open?: socket.assigns.custom_open? or form["from"] != "" or form["to"] != ""
     )
     |> load()}
  end

  defp load(%{assigns: %{viewing?: false}} = socket),
    do: assign(socket, messages: [], events: [], more?: false)

  defp load(%{assigns: %{tab: "events"}} = socket),
    do: assign(socket, events: ChatLog.events(socket.assigns.filters), messages: [], more?: false)

  defp load(socket) do
    messages = ChatLog.messages(Map.put(socket.assigns.filters, :limit, @page + 1))

    assign(socket,
      messages: Enum.take(messages, @page),
      more?: length(messages) > @page,
      events: []
    )
  end

  # This page with some filter values changed ("" removes one).
  defp page_path(assigns, changes, tab \\ nil) do
    query =
      assigns.form
      |> Map.merge(changes)
      |> ChatLogFilters.query()
      |> then(&if((tab || assigns.tab) == "events", do: Map.put(&1, "tab", "events"), else: &1))

    ~p"/admin/chat-log?#{query}"
  end

  ## Channels: logging and retention

  @impl true
  def handle_event("settings_search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, settings_q: q)}

  def handle_event("settings_show", %{"show" => show}, socket) when show in ~w(all on off),
    do: {:noreply, assign(socket, settings_show: show)}

  def handle_event("toggle_logging", %{"id" => id}, socket) do
    channel = Channels.get!(String.to_integer(id))
    configure(socket, channel, not channel.chat_log, channel.chat_log_retention_days)
  end

  def handle_event("retention", %{"channel_id" => id, "days" => days}, socket) do
    channel = Channels.get!(String.to_integer(id))

    case Integer.parse(days) do
      {days, ""} when days != channel.chat_log_retention_days ->
        configure(socket, channel, channel.chat_log, days)

      {_same, ""} ->
        {:noreply, socket}

      _ ->
        {:noreply, retention_error(socket)}
    end
  end

  ## Browse filters

  def handle_event("picker", _params, socket),
    do: {:noreply, assign(socket, picker_open?: not socket.assigns.picker_open?, picker_q: "")}

  def handle_event("picker_close", _params, socket),
    do: {:noreply, assign(socket, picker_open?: false)}

  def handle_event("picker_search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, picker_q: q)}

  def handle_event("pick", %{"id" => id}, socket) do
    channels = ChatLogFilters.toggle(socket.assigns.form["channels"], id)
    {:noreply, push_patch(socket, to: page_path(socket.assigns, %{"channels" => channels}))}
  end

  def handle_event("add_user", %{"user" => user}, socket) do
    case String.trim(user) do
      "" ->
        {:noreply, socket}

      user ->
        users = ChatLogFilters.items(socket.assigns.form["users"])
        users = if user in users, do: users, else: users ++ [user]

        {:noreply,
         push_patch(socket, to: page_path(socket.assigns, %{"users" => Enum.join(users, ",")}))}
    end
  end

  def handle_event("custom", _params, socket),
    do: {:noreply, assign(socket, custom_open?: not socket.assigns.custom_open?)}

  def handle_event("custom_period", %{"from" => from, "to" => to}, socket) do
    {:noreply,
     push_patch(socket,
       to: page_path(socket.assigns, %{"period" => "", "from" => from, "to" => to})
     )}
  end

  def handle_event("more", _params, socket) do
    last = List.last(socket.assigns.messages)

    more =
      socket.assigns.filters
      |> Map.merge(%{limit: @page + 1, before: {last.sent_at, last.message_id}})
      |> ChatLog.messages()

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ Enum.take(more, @page),
       more?: length(more) > @page
     )}
  end

  ## Deleting a period

  def handle_event("ask_delete", _params, socket) do
    # Starts from what is being looked at: its one channel and its period.
    slug =
      case ChatLogFilters.items(socket.assigns.form["channels"]) do
        [id] ->
          Enum.find_value(socket.assigns.channels, "", &(to_string(&1.id) == id && &1.slug))

        _ ->
          ""
      end

    {:noreply,
     assign(socket,
       deleting: %{
         "slug" => slug,
         "from" => socket.assigns.form["from"],
         "to" => socket.assigns.form["to"]
       }
     )}
  end

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, deleting: nil)}

  def handle_event("delete", %{"d" => d}, socket) do
    slug = String.trim(d["slug"] || "")
    channel = Enum.find(socket.assigns.channels, &(&1.slug == slug))
    from = ChatLogFilters.time(d["from"] || "")
    to = ChatLogFilters.time(d["to"] || "")

    cond do
      channel == nil ->
        {:noreply, refuse_delete(socket, d, gettext("No channel with that slug."))}

      from == nil or to == nil or DateTime.compare(from, to) != :lt ->
        {:noreply,
         refuse_delete(socket, d, gettext("Choose a period that ends after it starts."))}

      d["understood"] != "true" ->
        {:noreply, refuse_delete(socket, d, gettext("Confirm that the log is deleted for good."))}

      true ->
        {:ok, _} = KickTracker.Workers.ChatLog.delete(channel.id, from, to)

        Audit.log(socket.assigns.current_admin, "chat_log.delete", channel.slug, %{
          "from" => DateTime.to_iso8601(from),
          "to" => DateTime.to_iso8601(to)
        })

        {:noreply,
         socket
         |> assign(deleting: nil)
         |> put_flash(:info, gettext("Deletion queued; the collector runs it within seconds."))}
    end
  end

  defp refuse_delete(socket, d, message),
    do: socket |> assign(deleting: d) |> put_flash(:error, message)

  defp configure(socket, channel, enabled?, days) do
    case ChatLog.configure(channel, enabled?, days) do
      {:ok, updated} ->
        Audit.log(socket.assigns.current_admin, "chat_log.configure", updated.slug, %{
          "enabled" => updated.chat_log,
          "retention_days" => updated.chat_log_retention_days,
          "was_enabled" => channel.chat_log,
          "was_retention_days" => channel.chat_log_retention_days
        })

        {:noreply, load_channels(socket)}

      {:error, :bad_retention} ->
        {:noreply, retention_error(socket)}
    end
  end

  defp retention_error(socket) do
    socket
    |> load_channels()
    |> put_flash(
      :error,
      gettext("Retention is a number of days from 1 to %{max}.",
        max: ChatLog.max_retention_days()
      )
    )
  end

  @doc false
  # For the audit log: what a view or an export selected, without whom.
  def audit_view(socket_or_admin, action, filters, tab \\ "messages") do
    admin =
      case socket_or_admin do
        %Phoenix.LiveView.Socket{} = s -> s.assigns.current_admin
        admin -> admin
      end

    Audit.log(admin, action, nil, %{
      "tab" => tab,
      "channel_ids" => filters[:channel_ids],
      "by_user" => Map.has_key?(filters, :user_ids),
      "from" => filters[:from] && DateTime.to_iso8601(filters[:from]),
      "to" => filters[:to] && DateTime.to_iso8601(filters[:to])
    })
  end

  ## Rendering

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown_settings: settings_rows(assigns),
        picker_rows: picker_rows(assigns.logged, assigns.picker_q),
        picked: ChatLogFilters.items(assigns.form["channels"]),
        users: ChatLogFilters.items(assigns.form["users"]),
        slugs: Map.new(assigns.channels, &{to_string(&1.id), &1.slug})
      )

    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:chat_log}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold">{gettext("Chat log")}</h1>
          <p class="text-muted mt-1 max-w-2xl text-sm">
            {gettext(
              "Message text and chat events, kept only for channels logging is on for, for each channel's retention. Admin only; never shown on the public site. Times are UTC."
            )}
          </p>
        </div>
        <.link
          navigate={~p"/about/privacy#chat-logging"}
          class="text-muted inline-flex items-center gap-1 text-xs hover:underline"
        >
          <.icon name="hero-shield-check" class="size-4" />
          {gettext("What the privacy page tells chatters")}
        </.link>
      </div>

      <div id="chat-log-summary" class="mt-5 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <.summary_tile icon="hero-signal" label={gettext("Logging on")}>
          {@summary.logging}
          <span class="text-muted text-sm font-normal">
            / {ngettext("1 channel", "%{count} channels", @summary.channels)}
          </span>
        </.summary_tile>
        <.summary_tile icon="hero-chat-bubble-left-right" label={gettext("Messages kept")}>
          ≈ {format_count(@summary.messages)}
        </.summary_tile>
        <.summary_tile icon="hero-bolt" label={gettext("Chat events kept")}>
          {format_count(@summary.events)}
        </.summary_tile>
      </div>

      <div class="mt-6 grid gap-6 xl:grid-cols-[22rem_minmax(0,1fr)]">
        <%!-- Channels: logging and retention --%>
        <section id="chat-log-settings" class="card-surface flex flex-col self-start p-4">
          <header class="flex items-center justify-between gap-2">
            <h2 class="font-semibold">{gettext("Channels")}</h2>
            <span id="chat-log-settings-count" class="text-muted text-xs tabular-nums">
              {gettext("%{shown} of %{all}", shown: length(@shown_settings), all: length(@channels))}
            </span>
          </header>

          <form
            id="chat-log-settings-search"
            phx-change="settings_search"
            phx-submit="settings_search"
            class="mt-3"
          >
            <label class="input input-sm w-full">
              <.icon name="hero-magnifying-glass" class="text-muted size-4" />
              <input
                type="search"
                name="q"
                value={@settings_q}
                placeholder={gettext("Search channels")}
                phx-debounce="150"
                autocomplete="off"
              />
            </label>
          </form>

          <nav class="segmented mt-2 self-start" aria-label={gettext("Show")}>
            <button
              :for={
                {key, label} <- [
                  {"all", gettext("All")},
                  {"on", gettext("Logging")},
                  {"off", gettext("Off")}
                ]
              }
              id={"chat-log-show-#{key}"}
              type="button"
              phx-click="settings_show"
              phx-value-show={key}
              class={["segmented-item", @settings_show == key && "is-active"]}
            >
              {label}
            </button>
          </nav>

          <div class="scroll-panel mt-3 max-h-[32rem] overflow-y-auto">
            <ul id="chat-log-channels" role="list" class="divide-y divide-base-300">
              <li
                :for={c <- @shown_settings}
                id={"chat-log-channel-#{c.id}"}
                class="flex items-center gap-3 py-2 pe-1"
              >
                <.avatar name={c.slug} channel_id={c.id} class="size-8 text-sm" />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-medium" title={c.slug}>{c.slug}</p>
                  <div class="text-muted flex flex-wrap items-center gap-x-2 text-xs">
                    <form
                      id={"chat-log-config-#{c.id}"}
                      phx-change="retention"
                      phx-submit="retention"
                      class="inline-flex items-center gap-1"
                    >
                      <input type="hidden" name="channel_id" value={c.id} />
                      <input
                        name="days"
                        type="number"
                        min="1"
                        max={ChatLog.max_retention_days()}
                        value={c.chat_log_retention_days}
                        phx-debounce="blur"
                        aria-label={gettext("Days kept for %{slug}", slug: c.slug)}
                        class="retention-input"
                      />{gettext("days")}
                    </form>
                    <span :if={!c.active}>· {gettext("paused")}</span>
                    <span :if={!c.public}>· {gettext("hidden")}</span>
                  </div>
                </div>
                <input
                  id={"chat-log-toggle-#{c.id}"}
                  type="checkbox"
                  role="switch"
                  class="toggle toggle-sm toggle-warning"
                  checked={c.chat_log}
                  phx-click="toggle_logging"
                  phx-value-id={c.id}
                  aria-label={gettext("Log chat on %{slug}", slug: c.slug)}
                  data-confirm={
                    !c.chat_log &&
                      gettext(
                        "Log every message on %{slug}, with its sender, for %{days} days? Only turn this on with the streamer's agreement.",
                        slug: c.slug,
                        days: c.chat_log_retention_days
                      )
                  }
                />
              </li>
            </ul>
            <p :if={@shown_settings == []} class="text-muted py-6 text-center text-sm">
              {gettext("No channel matches.")}
            </p>
          </div>
        </section>

        <%!-- Browse --%>
        <section id="chat-log-browse" class="card-surface min-w-0 p-4">
          <header class="mb-3 flex flex-wrap items-center justify-between gap-2">
            <h2 class="font-semibold">{gettext("Browse")}</h2>
            <div class="flex items-center gap-1">
              <a
                :if={@viewing?}
                id="chat-log-export"
                href={~p"/admin/chat-log/export.csv?#{ChatLogFilters.query(@form)}"}
                class="btn btn-sm btn-ghost gap-1"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" />{gettext("Export CSV")}
              </a>
              <button
                id="chat-log-ask-delete"
                type="button"
                phx-click="ask_delete"
                class="btn btn-sm btn-ghost gap-1 text-error"
              >
                <.icon name="hero-trash" class="size-4" />{gettext("Delete a period…")}
              </button>
            </div>
          </header>
          <div class="flex flex-wrap items-center gap-2">
            <%!-- Channels picker --%>
            <div class="relative" phx-click-away={@picker_open? && "picker_close"}>
              <button
                id="chat-log-picker-button"
                type="button"
                phx-click="picker"
                aria-expanded={to_string(@picker_open?)}
                aria-controls="chat-log-picker"
                class="btn btn-sm btn-ghost gap-1 border border-base-300"
              >
                <.icon name="hero-rectangle-stack" class="size-4" />
                {if @picked == [],
                  do: gettext("All channels"),
                  else: ngettext("1 channel", "%{count} channels", length(@picked))}
                <.icon name="hero-chevron-down" class="size-3" />
              </button>
              <div
                :if={@picker_open?}
                id="chat-log-picker"
                class="card-surface popover-panel absolute start-0 z-20 mt-2 w-72 p-2"
              >
                <form
                  id="chat-log-picker-search"
                  phx-change="picker_search"
                  phx-submit="picker_search"
                >
                  <label class="input input-sm w-full">
                    <.icon name="hero-magnifying-glass" class="text-muted size-4" />
                    <input
                      type="search"
                      name="q"
                      value={@picker_q}
                      placeholder={gettext("Search channels with a log")}
                      phx-debounce="150"
                      phx-mounted={Phoenix.LiveView.JS.focus()}
                      autocomplete="off"
                    />
                  </label>
                </form>
                <ul
                  class="scroll-panel mt-2 max-h-72 overflow-y-auto"
                  role="listbox"
                  aria-multiselectable="true"
                >
                  <li :for={c <- @picker_rows}>
                    <button
                      id={"chat-log-pick-#{c.id}"}
                      type="button"
                      role="option"
                      aria-selected={to_string(to_string(c.id) in @picked)}
                      phx-click="pick"
                      phx-value-id={c.id}
                      class="picker-option"
                    >
                      <span class={["picker-check", to_string(c.id) in @picked && "is-checked"]}>
                        <.icon :if={to_string(c.id) in @picked} name="hero-check" class="size-3" />
                      </span>
                      <span class="min-w-0 flex-1 truncate">{c.slug}</span>
                      <span
                        :if={c.chat_log}
                        class="size-1.5 rounded-full bg-warning"
                        title={gettext("logging on")}
                      />
                    </button>
                  </li>
                </ul>
                <p :if={@picker_rows == []} class="text-muted px-2 py-4 text-center text-xs">
                  {if @logged == [],
                    do: gettext("No channel has a log yet."),
                    else: gettext("No channel matches.")}
                </p>
              </div>
            </div>

            <%!-- Users --%>
            <form id="chat-log-user" phx-submit="add_user">
              <label class="input input-sm w-48">
                <.icon name="hero-user" class="text-muted size-4" />
                <input name="user" placeholder={gettext("Add a user…")} autocomplete="off" />
              </label>
            </form>

            <%!-- Period --%>
            <nav class="segmented" aria-label={gettext("Period")}>
              <.link
                :for={p <- ChatLogFilters.periods()}
                id={"chat-log-period-#{p}"}
                patch={page_path(assigns, %{"period" => p, "from" => "", "to" => ""})}
                class={["segmented-item", @form["period"] == p && "is-active"]}
              >
                {period_label(p)}
              </.link>
              <button
                id="chat-log-period-custom"
                type="button"
                phx-click="custom"
                class={[
                  "segmented-item",
                  (@form["from"] != "" or @form["to"] != "") && "is-active"
                ]}
              >
                {gettext("Custom")}
              </button>
            </nav>
          </div>

          <form
            :if={@custom_open?}
            id="chat-log-custom"
            phx-submit="custom_period"
            class="inset-well mt-3 flex flex-wrap items-end gap-2 p-3"
          >
            <label class="text-muted text-xs">
              {gettext("From (UTC)")}
              <input
                type="datetime-local"
                name="from"
                value={@form["from"]}
                class="input input-sm mt-1 block"
              />
            </label>
            <label class="text-muted text-xs">
              {gettext("To (UTC)")}
              <input
                type="datetime-local"
                name="to"
                value={@form["to"]}
                class="input input-sm mt-1 block"
              />
            </label>
            <button class="btn btn-sm btn-primary">{gettext("Apply")}</button>
          </form>

          <%!-- Active filters --%>
          <div :if={@viewing?} id="chat-log-chips" class="mt-3 flex flex-wrap items-center gap-1.5">
            <.chip
              :for={id <- @picked}
              icon="hero-rectangle-stack"
              patch={
                page_path(assigns, %{"channels" => ChatLogFilters.toggle(@form["channels"], id)})
              }
            >
              {@slugs[id] || id}
            </.chip>
            <.chip
              :for={u <- @users}
              icon="hero-user"
              patch={page_path(assigns, %{"users" => Enum.join(@users -- [u], ",")})}
            >
              {u}
            </.chip>
            <.chip
              :if={@form["period"] != ""}
              icon="hero-clock"
              patch={page_path(assigns, %{"period" => ""})}
            >
              {gettext("last %{period}", period: period_label(@form["period"]))}
            </.chip>
            <.chip
              :if={@form["from"] != "" or @form["to"] != ""}
              icon="hero-clock"
              patch={page_path(assigns, %{"from" => "", "to" => ""})}
            >
              {period_range(@form)}
            </.chip>
            <.link patch={~p"/admin/chat-log"} class="text-muted ms-1 text-xs hover:underline">
              {gettext("Clear all")}
            </.link>
          </div>

          <%= if @viewing? do %>
            <.tabs
              id="chat-log-tabs"
              class="mt-4"
              active={@tab}
              tabs={[
                {"messages", gettext("Messages"), page_path(assigns, %{}, "messages")},
                {"events", gettext("Chat events"), page_path(assigns, %{}, "events")}
              ]}
            />

            <div class="scroll-panel mt-2 max-h-[70vh] overflow-y-auto">
              <ol :if={@tab == "messages"} id="chat-log-messages" class="pb-2">
                <%= for {day, messages} <- by_day(@messages) do %>
                  <li class="day-divider">{day}</li>
                  <li
                    :for={m <- messages}
                    id={"msg-#{m.channel_id}-#{m.message_id}"}
                    class="chat-row"
                  >
                    <.avatar name={m.username || to_string(m.user_id)} class="mt-0.5 size-8 text-sm" />
                    <div class="min-w-0 flex-1">
                      <div class="flex flex-wrap items-baseline gap-x-2 text-xs">
                        <.link
                          patch={page_path(assigns, %{"users" => to_string(m.user_id)})}
                          class="text-sm font-semibold hover:underline"
                        >
                          {m.username || m.user_id}
                        </.link>
                        <.link
                          patch={page_path(assigns, %{"channels" => to_string(m.channel_id)})}
                          class={["channel-pill", "avatar-#{hue(m.slug)}"]}
                        >
                          {m.slug}
                        </.link>
                        <time
                          class="text-subtle tabular-nums"
                          datetime={DateTime.to_iso8601(m.sent_at)}
                        >
                          {Calendar.strftime(m.sent_at, "%H:%M:%S")}
                        </time>
                      </div>
                      <p :if={m.reply_to_message_id} class="text-muted mt-0.5 text-xs">
                        <.icon name="hero-arrow-uturn-left" class="size-3" />
                        {gettext("reply")}
                        <span :if={m.reply_to_user_id}>
                          {gettext("to")}
                          <.link
                            patch={page_path(assigns, %{"users" => to_string(m.reply_to_user_id)})}
                            class="hover:underline"
                          >{m.reply_to_username || m.reply_to_user_id}</.link>
                        </span>
                      </p>
                      <p class="whitespace-pre-wrap break-words text-sm">{m.content}</p>
                    </div>
                  </li>
                <% end %>
              </ol>
              <.empty :if={@tab == "messages" and @messages == []} icon="hero-chat-bubble-left-right">
                {gettext("Nothing logged for these filters.")}
              </.empty>
              <div :if={@more?} class="flex justify-center py-2">
                <button id="chat-log-more" phx-click="more" class="btn btn-sm btn-ghost gap-1">
                  <.icon name="hero-arrow-down" class="size-4" />{gettext("Older messages")}
                </button>
              </div>

              <ol :if={@tab == "events"} id="chat-log-events" class="divide-y divide-base-300">
                <li :for={e <- @events} class="py-2">
                  <details class="group">
                    <summary class="flex cursor-pointer list-none items-center gap-3 text-sm">
                      <.icon
                        name="hero-chevron-right"
                        class="text-muted size-3 transition group-open:rotate-90 rtl:rotate-180"
                      />
                      <span class="font-mono text-xs">{short_event(e.event)}</span>
                      <span class={["channel-pill", "avatar-#{hue(e.slug)}"]}>{e.slug}</span>
                      <time class="text-subtle ms-auto text-xs tabular-nums">
                        {Calendar.strftime(e.occurred_at, "%Y-%m-%d %H:%M:%S")}
                      </time>
                    </summary>
                    <pre class="inset-well mt-2 overflow-x-auto p-3 text-xs">{Jason.encode!(e.payload, pretty: true)}</pre>
                  </details>
                </li>
              </ol>
              <.empty :if={@tab == "events" and @events == []} icon="hero-bolt">
                {gettext("No chat events logged for these filters.")}
              </.empty>
            </div>
          <% else %>
            <div id="chat-log-start" class="mt-10 mb-6 flex flex-col items-center gap-3 text-center">
              <span class="icon-tile"><.icon name="hero-chat-bubble-left-right" class="size-5" /></span>
              <p class="text-muted max-w-sm text-sm">
                {gettext("Pick channels, users or a period to read the log.")}
              </p>
              <.link
                id="chat-log-last-day"
                patch={page_path(assigns, %{"period" => "24h"})}
                class="btn btn-sm btn-primary"
              >
                {gettext("Show the last 24 hours")}
              </.link>
            </div>
          <% end %>
        </section>
      </div>

      <%!-- Delete a period --%>
      <div
        :if={@deleting}
        id="chat-log-delete-dialog"
        class="fixed inset-0 z-50 grid place-items-center bg-black/50 p-4"
        role="dialog"
        aria-modal="true"
        aria-labelledby="chat-log-delete-title"
        phx-window-keydown="cancel_delete"
        phx-key="Escape"
      >
        <form
          id="chat-log-delete"
          phx-submit="delete"
          phx-click-away="cancel_delete"
          class="card-surface w-full max-w-md space-y-3 p-5"
        >
          <div class="flex items-start gap-3">
            <span class="icon-tile text-error"><.icon name="hero-trash" class="size-5" /></span>
            <div>
              <h2 id="chat-log-delete-title" class="font-semibold">
                {gettext("Delete a period of a channel's log")}
              </h2>
              <p class="text-muted mt-1 text-xs">
                {gettext(
                  "Deletes the messages and chat events logged for the channel in the period, for good. Statistics (viewers, chat counts, follows, subs) are not touched."
                )}
              </p>
            </div>
          </div>
          <label class="block text-xs">
            <span class="text-muted">{gettext("Channel")}</span>
            <input
              name="d[slug]"
              value={@deleting["slug"]}
              list="chat-log-slugs"
              placeholder={gettext("Type or pick a slug")}
              autocomplete="off"
              class="input input-sm mt-1 w-full"
              required
            />
          </label>
          <datalist id="chat-log-slugs">
            <option :for={c <- @logged} value={c.slug} />
          </datalist>
          <div class="grid grid-cols-2 gap-2">
            <label class="block text-xs">
              <span class="text-muted">{gettext("From (UTC)")}</span>
              <input
                type="datetime-local"
                name="d[from]"
                value={@deleting["from"]}
                class="input input-sm mt-1 w-full"
                required
              />
            </label>
            <label class="block text-xs">
              <span class="text-muted">{gettext("To (UTC)")}</span>
              <input
                type="datetime-local"
                name="d[to]"
                value={@deleting["to"]}
                class="input input-sm mt-1 w-full"
                required
              />
            </label>
          </div>
          <label class="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              name="d[understood]"
              value="true"
              class="checkbox checkbox-sm checkbox-error"
            />
            {gettext("I understand this can't be undone.")}
          </label>
          <div class="flex justify-end gap-2 pt-1">
            <button type="button" phx-click="cancel_delete" class="btn btn-sm btn-ghost">
              {gettext("Cancel")}
            </button>
            <button class="btn btn-sm btn-error">{gettext("Delete")}</button>
          </div>
        </form>
      </div>
    </Layouts.admin>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp summary_tile(assigns) do
    ~H"""
    <div class="card-surface flex items-center gap-3 p-4">
      <span class="icon-tile"><.icon name={@icon} class="size-5" /></span>
      <div class="min-w-0">
        <p class="text-muted text-xs">{@label}</p>
        <p class="text-lg font-semibold tabular-nums">{render_slot(@inner_block)}</p>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :patch, :string, required: true
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <.link patch={@patch} class="filter-chip group" title={gettext("Remove this filter")}>
      <.icon name={@icon} class="text-muted size-3.5 shrink-0" />
      <span class="truncate">{render_slot(@inner_block)}</span>
      <.icon name="hero-x-mark" class="text-muted size-3.5 shrink-0 group-hover:text-error" />
    </.link>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp empty(assigns) do
    ~H"""
    <div class="text-muted flex flex-col items-center gap-2 py-10 text-sm">
      <.icon name={@icon} class="size-6 opacity-60" />
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp settings_rows(%{channels: channels, settings_q: q, settings_show: show}) do
    q = String.downcase(String.trim(q))

    Enum.filter(channels, fn c ->
      (q == "" or String.contains?(String.downcase(c.slug), q)) and
        (show == "all" or show == "on" == c.chat_log)
    end)
  end

  defp picker_rows(logged, q) do
    q = String.downcase(String.trim(q))
    Enum.filter(logged, &(q == "" or String.contains?(String.downcase(&1.slug), q)))
  end

  defp by_day(messages) do
    messages
    |> Enum.chunk_by(&DateTime.to_date(&1.sent_at))
    |> Enum.map(fn [m | _] = day -> {Calendar.strftime(m.sent_at, "%A %-d %B %Y"), day} end)
  end

  defp hue(name), do: :erlang.phash2(name, 7) + 1

  defp period_label("1h"), do: gettext("1h")
  defp period_label("24h"), do: gettext("24h")
  defp period_label("7d"), do: gettext("7d")
  defp period_label("30d"), do: gettext("30d")
  defp period_label(other), do: other

  defp period_range(form) do
    from = if form["from"] != "", do: String.replace(form["from"], "T", " "), else: "…"
    to = if form["to"] != "", do: String.replace(form["to"], "T", " "), else: "…"
    "#{from} – #{to}"
  end

  defp format_count(n) when is_integer(n) and n >= 1_000_000,
    do: "#{:erlang.float_to_binary(n / 1_000_000, decimals: 1)}M"

  defp format_count(n) when is_integer(n) and n >= 10_000, do: "#{div(n, 1000)}k"
  defp format_count(n) when is_integer(n), do: Integer.to_string(n)
  defp format_count(_), do: "–"

  defp short_event("App\\Events\\" <> name), do: name
  defp short_event(name), do: name
end
