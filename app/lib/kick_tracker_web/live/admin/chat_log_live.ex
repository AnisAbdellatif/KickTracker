defmodule KickTrackerWeb.Admin.ChatLogLive do
  @moduledoc """
  Chat logging (project.md §12.8), admin only: turn it on or off per
  channel and set how long each channel's log is kept; read the log by
  channel, by user (across channels) and period; export what the filters
  select as CSV; delete a channel's log for a period (the collector runs
  it, see `Workers.ChatLog`).

  The filters live in the URL, so a view is reproducible and shareable
  between admins. Views, exports, deletions and setting changes are
  audited; which users were looked up is not written down (as for privacy
  searches), only that a view was by user.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Channels, ChatLog}
  alias KickTrackerWeb.Admin.ChatLogFilters

  @page 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Chat log"),
       channels: Channels.list_all(),
       deleting: false,
       messages: [],
       events: [],
       more?: false
     )}
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

  @impl true
  def handle_event("filter", %{"f" => form}, socket) do
    form = Map.update(form, "channels", "", &Enum.join(List.wrap(&1), ","))
    query = form |> ChatLogFilters.query() |> put_tab(socket.assigns.tab)
    {:noreply, push_patch(socket, to: ~p"/admin/chat-log?#{query}")}
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

  def handle_event("configure", %{"channel_id" => id} = params, socket) do
    channel = Channels.get!(String.to_integer(id))
    enabled? = params["enabled"] == "true"

    with {days, ""} <- Integer.parse(params["retention_days"] || ""),
         {:ok, updated} <- ChatLog.configure(channel, enabled?, days) do
      Audit.log(socket.assigns.current_admin, "chat_log.configure", updated.slug, %{
        "enabled" => updated.chat_log,
        "retention_days" => updated.chat_log_retention_days,
        "was_enabled" => channel.chat_log,
        "was_retention_days" => channel.chat_log_retention_days
      })

      {:noreply, assign(socket, channels: Channels.list_all())}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Retention is a number of days from 1 to %{max}.",
             max: ChatLog.max_retention_days()
           )
         )}
    end
  end

  def handle_event("ask_delete", _params, socket), do: {:noreply, assign(socket, deleting: true)}

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, deleting: false)}

  def handle_event("delete", %{"d" => d}, socket) do
    channel = Enum.find(socket.assigns.channels, &(to_string(&1.id) == d["channel_id"]))
    from = ChatLogFilters.time(d["from"] || "")
    to = ChatLogFilters.time(d["to"] || "")

    cond do
      channel == nil or from == nil or to == nil or DateTime.compare(from, to) != :lt ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Choose a channel and a period that ends after it starts.")
         )}

      String.trim(d["confirm"] || "") != channel.slug ->
        {:noreply, put_flash(socket, :error, gettext("Type the slug exactly to confirm."))}

      true ->
        {:ok, _} = KickTracker.Workers.ChatLog.delete(channel.id, from, to)

        Audit.log(socket.assigns.current_admin, "chat_log.delete", channel.slug, %{
          "from" => DateTime.to_iso8601(from),
          "to" => DateTime.to_iso8601(to)
        })

        {:noreply,
         socket
         |> assign(deleting: false)
         |> put_flash(:info, gettext("Deletion queued; the collector runs it within seconds."))}
    end
  end

  defp put_tab(query, "events"), do: Map.put(query, "tab", "events")
  defp put_tab(query, _), do: query

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:chat_log}>
      <.header>
        {gettext("Chat log")}
        <:subtitle>
          {gettext(
            "Message text and chat events, kept only for channels logging is turned on for, for each channel's retention. Admin only; never shown on the public site. Times are UTC."
          )}
        </:subtitle>
      </.header>

      <section id="chat-log-settings" class="mb-8">
        <h2 class="mb-2 font-semibold">{gettext("Logging per channel")}</h2>
        <.table id="chat-log-channels" rows={@channels} row_id={&"chat-log-channel-#{&1.id}"}>
          <:col :let={c} label={gettext("Channel")}>
            <span class="font-medium">{c.slug}</span>
            <span :if={!c.active} class="text-xs opacity-60">({gettext("paused")})</span>
          </:col>
          <:col :let={c} label={gettext("Logging")}>
            <span :if={c.chat_log} class="badge badge-warning badge-sm">{gettext("on")}</span>
            <span :if={!c.chat_log} class="text-xs opacity-60">{gettext("off")}</span>
          </:col>
          <:col :let={c} label={gettext("Kept for (days)")}>
            <form
              id={"chat-log-config-#{c.id}"}
              phx-submit="configure"
              class="flex items-center gap-1"
            >
              <input type="hidden" name="channel_id" value={c.id} />
              <input type="hidden" name="enabled" value={to_string(c.chat_log)} />
              <input
                name="retention_days"
                type="number"
                min="1"
                max={ChatLog.max_retention_days()}
                value={c.chat_log_retention_days}
                class="input input-xs w-20"
              />
              <button class="btn btn-xs btn-ghost">{gettext("Save")}</button>
            </form>
          </:col>
          <:action :let={c}>
            <form id={"chat-log-toggle-#{c.id}"} phx-submit="configure">
              <input type="hidden" name="channel_id" value={c.id} />
              <input type="hidden" name="enabled" value={to_string(!c.chat_log)} />
              <input type="hidden" name="retention_days" value={c.chat_log_retention_days} />
              <button
                class={["btn btn-xs", c.chat_log && "btn-ghost", !c.chat_log && "btn-warning"]}
                data-confirm={
                  !c.chat_log &&
                    gettext(
                      "Log every message on %{slug}, with its sender, for %{days} days? Only turn this on with the streamer's agreement.",
                      slug: c.slug,
                      days: c.chat_log_retention_days
                    )
                }
              >
                {if c.chat_log, do: gettext("Turn off"), else: gettext("Turn on")}
              </button>
            </form>
          </:action>
        </.table>
      </section>

      <section id="chat-log-browse">
        <h2 class="mb-2 font-semibold">{gettext("Browse")}</h2>
        <form id="chat-log-filter" phx-submit="filter" class="flex flex-wrap items-end gap-2">
          <label class="text-xs">
            {gettext("Channels")}
            <select name="f[channels][]" multiple size="4" class="select select-sm block h-auto w-48">
              <option
                :for={c <- @channels}
                value={c.id}
                selected={to_string(c.id) in String.split(@form["channels"], ",")}
              >
                {c.slug}
              </option>
            </select>
            <span class="opacity-60">{gettext("none selected: all")}</span>
          </label>
          <label class="text-xs">
            {gettext("Users")}
            <input
              name="f[users]"
              value={@form["users"]}
              class="input input-sm block w-56"
              placeholder={gettext("usernames or ids, comma-separated")}
            />
          </label>
          <label class="text-xs">
            {gettext("From (UTC)")}
            <input
              type="datetime-local"
              name="f[from]"
              value={@form["from"]}
              class="input input-sm block"
            />
          </label>
          <label class="text-xs">
            {gettext("To (UTC)")}
            <input
              type="datetime-local"
              name="f[to]"
              value={@form["to"]}
              class="input input-sm block"
            />
          </label>
          <button class="btn btn-sm">{gettext("Show")}</button>
          <a
            :if={@viewing?}
            id="chat-log-export"
            href={~p"/admin/chat-log/export.csv?#{ChatLogFilters.query(@form)}"}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Export CSV")}
          </a>
          <button type="button" phx-click="ask_delete" class="btn btn-sm btn-ghost text-error">
            {gettext("Delete a period…")}
          </button>
        </form>

        <form
          :if={@deleting}
          id="chat-log-delete"
          phx-submit="delete"
          class="mt-3 flex flex-wrap items-end gap-2 rounded-box border border-error p-3"
        >
          <label class="text-xs">
            {gettext("Channel")}
            <select name="d[channel_id]" class="select select-sm block w-48">
              <option :for={c <- @channels} value={c.id}>{c.slug}</option>
            </select>
          </label>
          <label class="text-xs">
            {gettext("From (UTC)")}
            <input type="datetime-local" name="d[from]" class="input input-sm block" required />
          </label>
          <label class="text-xs">
            {gettext("To (UTC)")}
            <input type="datetime-local" name="d[to]" class="input input-sm block" required />
          </label>
          <label class="text-xs">
            {gettext("Type the channel's slug")}
            <input name="d[confirm]" class="input input-sm block w-40" autocomplete="off" />
          </label>
          <button class="btn btn-sm btn-error">{gettext("Delete its log for this period")}</button>
          <button type="button" phx-click="cancel_delete" class="btn btn-sm btn-ghost">
            {gettext("Cancel")}
          </button>
          <p class="w-full text-xs opacity-70">
            {gettext(
              "Deletes the messages and chat events logged for the channel in the period. Statistics (viewers, chat counts, follows, subs) are not touched."
            )}
          </p>
        </form>

        <div :if={@viewing?} class="mt-4">
          <div role="tablist" class="tabs tabs-border">
            <.link
              role="tab"
              patch={~p"/admin/chat-log?#{ChatLogFilters.query(@form)}"}
              class={["tab", @tab == "messages" && "tab-active"]}
            >
              {gettext("Messages")}
            </.link>
            <.link
              role="tab"
              patch={~p"/admin/chat-log?#{Map.put(ChatLogFilters.query(@form), "tab", "events")}"}
              class={["tab", @tab == "events" && "tab-active"]}
            >
              {gettext("Chat events")}
            </.link>
          </div>

          <table :if={@tab == "messages"} id="chat-log-messages" class="table table-sm mt-2">
            <thead>
              <tr>
                <th>{gettext("Time")}</th>
                <th>{gettext("Channel")}</th>
                <th>{gettext("User")}</th>
                <th>{gettext("Message")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={m <- @messages} id={"msg-#{m.channel_id}-#{m.message_id}"}>
                <td class="whitespace-nowrap text-xs tabular-nums">
                  {Calendar.strftime(m.sent_at, "%Y-%m-%d %H:%M:%S")}
                </td>
                <td class="text-xs">
                  <.link
                    patch={~p"/admin/chat-log?#{%{"channels" => m.channel_id}}"}
                    class="link link-hover"
                  >
                    {m.slug}
                  </.link>
                </td>
                <td class="text-xs">
                  <.link
                    patch={~p"/admin/chat-log?#{%{"users" => m.user_id}}"}
                    class="link link-hover"
                  >
                    {m.username || m.user_id}
                  </.link>
                </td>
                <td class="text-sm break-words">
                  <span :if={m.reply_to_message_id} class="me-1 text-xs opacity-60">
                    ↩ {gettext("reply")}
                    <span :if={m.reply_to_user_id}>
                      {gettext("to")}
                      <.link
                        patch={~p"/admin/chat-log?#{%{"users" => m.reply_to_user_id}}"}
                        class="link link-hover"
                      >
                        {m.reply_to_user_id}
                      </.link>
                    </span>
                  </span>
                  {m.content}
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@tab == "messages" and @messages == []} class="mt-3 text-sm opacity-70">
            {gettext("Nothing logged for these filters.")}
          </p>
          <button :if={@more?} id="chat-log-more" phx-click="more" class="btn btn-sm btn-ghost mt-2">
            {gettext("Older messages")}
          </button>

          <table :if={@tab == "events"} id="chat-log-events" class="table table-sm mt-2">
            <thead>
              <tr>
                <th>{gettext("Time")}</th>
                <th>{gettext("Channel")}</th>
                <th>{gettext("Event")}</th>
                <th>{gettext("As sent")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @events}>
                <td class="whitespace-nowrap text-xs tabular-nums">
                  {Calendar.strftime(e.occurred_at, "%Y-%m-%d %H:%M:%S")}
                </td>
                <td class="text-xs">{e.slug}</td>
                <td class="font-mono text-xs">{short_event(e.event)}</td>
                <td>
                  <details>
                    <summary class="cursor-pointer text-xs opacity-70">{gettext("show")}</summary>
                    <pre class="max-w-xl overflow-x-auto text-xs">{Jason.encode!(e.payload, pretty: true)}</pre>
                  </details>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@tab == "events" and @events == []} class="mt-3 text-sm opacity-70">
            {gettext("No chat events logged for these filters.")}
          </p>
        </div>
        <p :if={!@viewing?} class="mt-4 text-sm opacity-70">
          {gettext("Choose a channel, users or a period to read the log.")}
        </p>
      </section>
    </Layouts.admin>
    """
  end

  defp short_event("App\\Events\\" <> name), do: name
  defp short_event(name), do: name
end
