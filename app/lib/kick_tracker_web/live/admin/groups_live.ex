defmodule KickTrackerWeb.Admin.GroupsLive do
  @moduledoc "Channel groups (project.md §13.8): lists of channels for public leaderboards and the compare page."

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Cache, Channels, Groups}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Groups"), channels: Channels.list_all(), editing: nil)
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
    do: {:noreply, assign(socket, editing: String.to_integer(id))}

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:groups}>
      <.header>
        {gettext("Groups")}
        <:subtitle>
          {gettext(
            "Public groups get their own leaderboard on the home page and a shortcut on the compare page."
          )}
        </:subtitle>
      </.header>
      <form id="create-group" phx-submit="create" class="flex items-center gap-2">
        <input
          name="name"
          class="input input-sm w-64"
          placeholder={gettext("e.g. Tunisian streamers")}
          required
        />
        <label class="flex items-center gap-1 text-sm"><input
          type="checkbox"
          name="public"
          value="true"
          class="checkbox checkbox-sm"
        /> {gettext("public")}</label>
        <button class="btn btn-sm">{gettext("Create")}</button>
      </form>
      <ul id="groups" class="mt-4 space-y-3">
        <li :for={g <- @groups} id={"group-#{g.id}"} class="rounded-box border border-base-300 p-3">
          <div class="flex items-center gap-2">
            <span class="font-medium">{g.name}</span>
            <span :if={g.public} class="badge badge-sm">{gettext("public")}</span>
            <span class="text-xs opacity-60">{ngettext(
              "1 channel",
              "%{count} channels",
              length(g.channel_ids)
            )}</span>
            <span class="flex-1"></span>
            <button phx-click="edit" phx-value-id={g.id} class="btn btn-xs btn-ghost">{gettext("Edit")}</button>
            <button
              phx-click="delete"
              phx-value-id={g.id}
              data-confirm={gettext("Delete this group?")}
              class="btn btn-xs btn-ghost"
            >{gettext("Delete")}</button>
          </div>
          <form :if={@editing == g.id} id={"members-#{g.id}"} phx-submit="members" class="mt-3">
            <input type="hidden" name="group_id" value={g.id} />
            <div class="grid grid-cols-2 gap-1 sm:grid-cols-4">
              <label :for={c <- @channels} class="flex items-center gap-1 text-sm">
                <input
                  type="checkbox"
                  name="channels[]"
                  value={c.id}
                  checked={c.id in g.channel_ids}
                  class="checkbox checkbox-xs"
                /> {c.slug}
              </label>
            </div>
            <label class="mt-2 flex items-center gap-1 text-sm"><input
              type="checkbox"
              name="public"
              value="true"
              checked={g.public}
              class="checkbox checkbox-sm"
            /> {gettext("public")}</label>
            <button class="btn btn-sm mt-2">{gettext("Save")}</button>
          </form>
        </li>
      </ul>
    </Layouts.admin>
    """
  end
end
