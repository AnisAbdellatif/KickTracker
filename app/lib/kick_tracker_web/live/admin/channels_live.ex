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
     |> assign(page_title: gettext("Channels"), preview: nil, editing: nil)
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:channels}>
      <.header>
        {gettext("Channels")}
        <:subtitle>
          {gettext("Pausing stops collection and keeps every row already collected.")}
        </:subtitle>
      </.header>

      <section class="rounded-box border border-base-300 p-4">
        <.form for={@lookup} id="lookup-form" phx-submit="lookup" class="flex items-end gap-2">
          <div class="flex-1 max-w-sm">
            <.input
              field={@lookup[:slug]}
              label={gettext("Add a channel by its Kick slug")}
              placeholder="somestreamer"
              required
            />
          </div>
          <.button class="btn mb-2" phx-disable-with={gettext("Looking up…")}>{gettext("Look up")}</.button>
        </.form>

        <div :if={@preview} id="channel-preview" class="mt-4 grid gap-4 sm:grid-cols-2">
          <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
            <dt class="opacity-60">{gettext("Slug")}</dt><dd class="font-medium">{@preview.slug}</dd>
            <dt class="opacity-60">{gettext("Kick user id")}</dt><dd>{@preview.kick_user_id}</dd>
            <dt class="opacity-60">{gettext("Status")}</dt>
            <dd>
              <%= if @preview.live? do %>
                <span class="badge badge-error badge-sm">{gettext("live")}</span>
                {gettext("%{n} viewers", n: @preview.viewers)}
              <% else %>
                {gettext("offline")}
              <% end %>
            </dd>
            <dt class="opacity-60">{gettext("Category")}</dt><dd>{@preview.category || "–"}</dd>
            <dt class="opacity-60">{gettext("Title")}</dt><dd class="break-words">
              {@preview.title || "–"}
            </dd>
            <dt class="opacity-60">{gettext("Language")}</dt><dd>{@preview.language || "–"}</dd>
          </dl>
          <div>
            <p :if={@preview.existing} class="mb-2 text-sm text-warning">
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
      </section>

      <datalist id="timezones">
        <option :for={tz <- @timezones} value={tz} />
      </datalist>

      <.table id="channels" rows={@channels} row_id={&"channel-#{&1.id}"}>
        <:col :let={c} label={gettext("Channel")}>
          <span class="font-medium">{c.slug}</span>
          <span :if={Map.has_key?(@live, c.id)} class="badge badge-error badge-xs ms-1">{gettext(
            "live"
          )}</span>
        </:col>
        <:col :let={c} label={gettext("Kick ids")}>
          <span class="text-xs opacity-70">
            {gettext("user")} {c.kick_user_id} · {gettext("chatroom")} {c.chatroom_id || "?"}
          </span>
        </:col>
        <:col :let={c} label={gettext("Timezone")}>
          <%= if @editing == c.id do %>
            <form id={"tz-form-#{c.id}"} phx-submit="save_tz" class="flex gap-1">
              <input type="hidden" name="channel_id" value={c.id} />
              <input name="timezone" value={c.timezone} list="timezones" class="input input-xs w-40" />
              <button class="btn btn-xs">{gettext("Save")}</button>
            </form>
          <% else %>
            <button phx-click="edit_tz" phx-value-id={c.id} class="link link-hover">{c.timezone}</button>
          <% end %>
        </:col>
        <:col :let={c} label={gettext("Tracked since")}>
          {Calendar.strftime(c.tracked_since, "%Y-%m-%d")}
        </:col>
        <:col :let={c} label={gettext("Status")}>
          {if c.active, do: gettext("tracking"), else: gettext("paused")}
        </:col>
        <:action :let={c}>
          <button
            id={"toggle-#{c.id}"}
            phx-click="toggle"
            phx-value-id={c.id}
            data-confirm={
              if c.active,
                do:
                  gettext("Pause tracking %{slug}? Nothing is collected while paused.", slug: c.slug)
            }
            class="btn btn-ghost btn-xs"
          >
            {if c.active, do: gettext("Pause"), else: gettext("Resume")}
          </button>
        </:action>
      </.table>
    </Layouts.admin>
    """
  end
end
