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
      <.page_header title={gettext("Privacy requests")} icon="hero-shield-check">
        <:subtitle>
          {gettext(
            "Find what we hold about a Kick user and delete what identifies them. Counts they contributed to stay, without them. Searches are audited without what was searched for."
          )}
        </:subtitle>
      </.page_header>

      <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
        <.panel title={gettext("Find a person")} icon="hero-magnifying-glass">
          <form id="find-user" phx-submit="find" class="flex gap-2">
            <label class="input input-sm flex-1">
              <.icon name="hero-user" class="text-muted size-4" />
              <input
                name="q"
                value={@query}
                placeholder={gettext("Kick user id or username")}
                autocomplete="off"
                required
              />
            </label>
            <button class="btn btn-sm btn-primary">{gettext("Find")}</button>
          </form>
          <p class="text-muted mt-3 text-xs">
            {gettext(
              "A request usually names a Kick username; the id is what stays the same when they rename."
            )}
          </p>
        </.panel>

        <.panel
          :if={@found}
          id="found"
          title={@found.username || gettext("Unknown username")}
          icon="hero-user"
        >
          <:subtitle><span class="font-mono">{@found.user_id}</span></:subtitle>
          <dl class="kv-list">
            <dt>{gettext("Chat minutes")}</dt><dd>{@found.chat_minutes}</dd>
            <dt>{gettext("Streams chatted in")}</dt><dd>{@found.chat_streams}</dd>
            <dt>{gettext("Follows")}</dt><dd>{@found.follows}</dd>
            <dt>{gettext("Support events")}</dt><dd>{@found.support_events}</dd>
            <dt>{gettext("Raw events mentioning the id")}</dt><dd>{@found.webhook_events}</dd>
            <dt>{gettext("Hosts mentioning the id")}</dt><dd>{@found.channel_events}</dd>
            <dt>{gettext("Logged chat messages")}</dt><dd>{@found.chat_messages}</dd>
            <dt>{gettext("Logged chat events mentioning the id")}</dt><dd>
              {@found.chat_log_events}
            </dd>
          </dl>
          <form id="delete-user" phx-submit="delete" class="inset-well mt-4 space-y-2 p-3">
            <p class="text-sm">
              {gettext(
                "Deleting removes the username, per-person rows and logged messages, and scrubs raw records. It can't be undone."
              )}
            </p>
            <div class="flex gap-2">
              <input
                name="confirm"
                class="input input-sm flex-1"
                placeholder={gettext("Type %{id} to confirm", id: @found.user_id)}
                autocomplete="off"
              />
              <button class="btn btn-sm btn-error gap-1">
                <.icon name="hero-trash" class="size-4" />{gettext("Delete")}
              </button>
            </div>
          </form>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
