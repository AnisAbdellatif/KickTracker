defmodule KickTrackerWeb.Admin.GroupsLive do
  @moduledoc "Channel groups (project.md §13.8): lists of channels for public leaderboards and the compare page."

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Cache, Channels, Groups}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Groups"), channels: Channels.list_all(), editing: nil)
     |> assign(member_q: "")
     |> load()}
  end

  defp load(socket), do: assign(socket, groups: Groups.list())

  @impl true
  def handle_event("create", %{"name" => name} = params, socket) do
    case Groups.create(name, params["public"] == "true") do
      {:ok, id} ->
        Audit.log(socket.assigns.current_admin, "group.create", name, %{"id" => id})
        {:noreply, socket |> assign(editing: id) |> load()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing: String.to_integer(id), member_q: "")}

  def handle_event("members", %{"group_id" => id} = params, socket) do
    ids = params |> Map.get("channels", []) |> Enum.map(&String.to_integer/1)
    id = String.to_integer(id)
    Groups.set_members(id, ids)
    Groups.set_public(id, params["public"] == "true")
    Cache.clear()

    Audit.log(socket.assigns.current_admin, "group.update", to_string(id), %{
      "channels" => ids,
      "public" => params["public"] == "true"
    })

    {:noreply, socket |> assign(editing: nil) |> load()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Groups.delete(String.to_integer(id))
    Audit.log(socket.assigns.current_admin, "group.delete", id)
    {:noreply, load(socket)}
  end

  # Typed in the member list's search box (inside the members form, so
  # sent on each key rather than as a form of its own).
  def handle_event("member_search", %{"value" => q}, socket),
    do: {:noreply, assign(socket, member_q: q)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, by_id: Map.new(assigns.channels, &{&1.id, &1}))

    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:groups}>
      <.page_header title={gettext("Groups")} icon="hero-rectangle-group">
        <:subtitle>
          {gettext(
            "Lists of channels. Public groups get their own leaderboard on the home page and a shortcut on the compare page."
          )}
        </:subtitle>
      </.page_header>

      <div class="grid items-start gap-6 lg:grid-cols-[20rem_minmax(0,1fr)]">
        <.panel title={gettext("New group")} icon="hero-plus-circle">
          <form id="create-group" phx-submit="create" class="space-y-3">
            <label class="block text-sm">
              <span class="text-muted">{gettext("Name")}</span>
              <input
                name="name"
                class="input input-sm mt-1 w-full"
                placeholder={gettext("e.g. Tunisian streamers")}
                required
              />
            </label>
            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="public"
                value="true"
                class="toggle toggle-sm toggle-primary"
              />
              {gettext("Public (shown on the site)")}
            </label>
            <button class="btn btn-sm btn-primary w-full">{gettext("Create")}</button>
          </form>
        </.panel>

        <div id="groups" class="space-y-4">
          <.panel :if={@groups == []}>
            <.empty_state icon="hero-rectangle-group" title={gettext("No groups yet.")}>
              {gettext("Create one, then pick its channels.")}
            </.empty_state>
          </.panel>

          <section :for={g <- @groups} id={"group-#{g.id}"} class="card-surface">
            <header class="flex flex-wrap items-center gap-2 border-b border-base-300 px-4 py-3">
              <h2 class="font-semibold">{g.name}</h2>
              <.status_pill tone={if g.public, do: :ok, else: :neutral}>
                {if g.public, do: gettext("public"), else: gettext("private")}
              </.status_pill>
              <span class="text-muted text-xs">
                {ngettext("1 channel", "%{count} channels", length(g.channel_ids))}
              </span>
              <span class="flex-1"></span>
              <.icon_button
                :if={@editing != g.id}
                icon="hero-pencil-square"
                label={gettext("Edit")}
                phx-click="edit"
                phx-value-id={g.id}
              />
              <.icon_button
                icon="hero-trash"
                label={gettext("Delete")}
                tone={:danger}
                phx-click="delete"
                phx-value-id={g.id}
                data-confirm={gettext("Delete this group?")}
              />
            </header>

            <div :if={@editing != g.id} class="flex flex-wrap gap-1.5 p-4">
              <span
                :for={id <- g.channel_ids}
                :if={@by_id[id]}
                class="inset-well inline-flex items-center gap-1.5 py-1 ps-1 pe-2.5 text-sm"
              >
                <.avatar name={@by_id[id].slug} channel_id={id} class="size-5 text-[0.6rem]" />
                {@by_id[id].slug}
              </span>
              <p :if={g.channel_ids == []} class="text-muted text-sm">
                {gettext("No channels yet: edit the group to add some.")}
              </p>
            </div>

            <form
              :if={@editing == g.id}
              id={"members-#{g.id}"}
              phx-submit="members"
              class="space-y-3 p-4"
            >
              <input type="hidden" name="group_id" value={g.id} />
              <div class="flex flex-wrap items-center justify-between gap-2">
                <p class="text-muted text-sm">{gettext("Channels in the group")}</p>
                <label class="input input-sm w-full sm:w-64">
                  <.icon name="hero-magnifying-glass" class="text-muted size-4" />
                  <input
                    type="search"
                    value={@member_q}
                    placeholder={gettext("Search channels")}
                    phx-keyup="member_search"
                    phx-debounce="150"
                    name="member_q"
                    autocomplete="off"
                  />
                </label>
              </div>
              <div class="scroll-panel inset-well max-h-72 overflow-y-auto p-2">
                <div class="grid grid-cols-1 gap-0.5 sm:grid-cols-2 lg:grid-cols-3">
                  <label
                    :for={c <- @channels}
                    class={[
                      "flex cursor-pointer items-center gap-2 rounded-[var(--radius-field)] px-2 py-1 text-sm hover:bg-[var(--surface-hover)]",
                      !matches?(c, @member_q) && "hidden"
                    ]}
                  >
                    <input
                      type="checkbox"
                      name="channels[]"
                      value={c.id}
                      checked={c.id in g.channel_ids}
                      class="checkbox checkbox-xs checkbox-primary"
                    />
                    <span class="truncate">{c.slug}</span>
                  </label>
                </div>
              </div>
              <div class="flex flex-wrap items-center justify-between gap-2">
                <label class="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    name="public"
                    value="true"
                    checked={g.public}
                    class="toggle toggle-sm toggle-primary"
                  />
                  {gettext("Public (shown on the site)")}
                </label>
                <div class="flex gap-2">
                  <button type="button" phx-click="cancel" class="btn btn-sm btn-ghost">{gettext(
                    "Cancel"
                  )}</button>
                  <button class="btn btn-sm btn-primary">{gettext("Save")}</button>
                </div>
              </div>
            </form>
          </section>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp matches?(_channel, q) when q in [nil, ""], do: true

  defp matches?(channel, q),
    do: String.contains?(String.downcase(channel.slug), String.downcase(String.trim(q)))
end
