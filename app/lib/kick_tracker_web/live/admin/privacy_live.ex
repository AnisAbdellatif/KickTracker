defmodule KickTrackerWeb.Admin.PrivacyLive do
  @moduledoc """
  Deletion requests (project.md §13.8): find everything held about a
  Kick user, by id or username, and delete it (the collector runs it; see
  `KickTracker.Privacy`). Typing the id again confirms.
  """

  use KickTrackerWeb, :live_view

  import Ecto.Query
  alias KickTracker.{Audit, Privacy, Repo}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Privacy"), found: nil, query: "")}
  end

  @impl true
  def handle_event("find", %{"q" => q}, socket) when is_binary(q) do
    q = String.trim(q)

    {by, user_id} =
      case Integer.parse(q) do
        {id, ""} ->
          {"id", id}

        _ ->
          {"username",
           Repo.one(
             from k in "kick_users",
               where: fragment("lower(?)", k.username) == ^String.downcase(q),
               select: k.id
           )}
      end

    found = user_id && Privacy.find(user_id)

    # That a search happened, never what was searched for: the term is
    # often a username, maybe of someone we hold nothing about, and a
    # later deletion couldn't reach it in the audit log.
    Audit.log(socket.assigns.current_admin, "privacy.find", nil, %{
      "by" => by,
      "found" => found != nil
    })

    {:noreply,
     socket
     |> assign(found: found, query: q)
     |> then(fn s ->
       if found, do: s, else: put_flash(s, :error, gettext("Nobody by that id or username."))
     end)}
  end

  def handle_event("find", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"confirm" => confirm}, socket) do
    found = socket.assigns.found

    if found && confirm == to_string(found.user_id) do
      {:ok, _} = KickTracker.Workers.Privacy.new(%{"user_id" => found.user_id}) |> Oban.insert()
      Audit.log(socket.assigns.current_admin, "privacy.delete", to_string(found.user_id))

      {:noreply,
       socket
       |> assign(found: nil)
       |> put_flash(:info, gettext("Deletion queued; the collector runs it within seconds."))}
    else
      {:noreply, put_flash(socket, :error, gettext("Type the user id to confirm."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:privacy}>
      <.header>
        {gettext("Privacy requests")}
        <:subtitle>
          {gettext(
            "Find what we hold about a Kick user and delete what identifies them. Counts they contributed to stay, without them."
          )}
        </:subtitle>
      </.header>
      <form id="find-user" phx-submit="find" class="flex gap-2">
        <input
          name="q"
          value={@query}
          class="input input-sm w-64"
          placeholder={gettext("Kick user id or username")}
          required
        />
        <button class="btn btn-sm">{gettext("Find")}</button>
      </form>
      <section
        :if={@found}
        id="found"
        class="mt-4 max-w-lg card-surface p-4 text-sm"
      >
        <dl class="grid grid-cols-[1fr_auto] gap-x-4 gap-y-1">
          <dt>{gettext("User id")}</dt><dd class="font-mono">{@found.user_id}</dd>
          <dt>{gettext("Username")}</dt><dd>{@found.username || "–"}</dd>
          <dt>{gettext("Chat minutes")}</dt><dd>{@found.chat_minutes}</dd>
          <dt>{gettext("Streams chatted in")}</dt><dd>{@found.chat_streams}</dd>
          <dt>{gettext("Follows")}</dt><dd>{@found.follows}</dd>
          <dt>{gettext("Support events")}</dt><dd>{@found.support_events}</dd>
          <dt>{gettext("Raw events mentioning the id")}</dt><dd>{@found.webhook_events}</dd>
        </dl>
        <form id="delete-user" phx-submit="delete" class="mt-4 flex gap-2">
          <input
            name="confirm"
            class="input input-sm flex-1"
            placeholder={gettext("Type %{id} to confirm", id: @found.user_id)}
            autocomplete="off"
          />
          <button class="btn btn-sm btn-error">{gettext("Delete")}</button>
        </form>
      </section>
    </Layouts.admin>
    """
  end
end
