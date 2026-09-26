defmodule KickTrackerWeb.Admin.DataLive do
  @moduledoc """
  Repairs (project.md §13.8), all layered on the raw facts: exclude a
  stream or merge it into the previous one, annotate a channel's
  timeline, and reprocess a range (recompute the rollups, or replay stored
  webhook events through the current handlers). The collector does the
  recomputing; this page queues it.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Annotations, Audit, Channels, Corrections, Reports}
  alias KickTracker.Workers.Reprocess

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Corrections"), channels: Channels.list_all())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    channel =
      case Integer.parse(params["channel"] || "") do
        {id, ""} -> Enum.find(socket.assigns.channels, &(&1.id == id))
        _ -> List.first(socket.assigns.channels)
      end

    {:noreply, socket |> assign(channel: channel) |> load()}
  end

  defp load(%{assigns: %{channel: nil}} = socket),
    do: assign(socket, stream_rows: [], corrections: [], annotations: Annotations.list())

  defp load(%{assigns: %{channel: c}} = socket) do
    assign(socket,
      stream_rows: Reports.streams(c, limit: 30),
      corrections: Corrections.list(c.id),
      annotations: Annotations.list(c.id)
    )
  end

  @impl true
  def handle_event("pick", %{"channel" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/admin/data?channel=#{id}")}

  def handle_event("exclude", %{"stream" => id, "note" => note}, socket) do
    result(socket, Corrections.exclude(String.to_integer(id), note, socket.assigns.current_admin))
  end

  def handle_event("merge", %{"stream" => id}, socket) do
    # Into the stream listed just before it (the list is newest first).
    streams = socket.assigns.stream_rows
    idx = Enum.find_index(streams, &(to_string(&1.id) == id))
    previous = idx && Enum.at(streams, idx + 1)

    if previous,
      do:
        result(
          socket,
          Corrections.merge(previous.id, String.to_integer(id), "", socket.assigns.current_admin)
        ),
      else: {:noreply, put_flash(socket, :error, gettext("No earlier stream to merge into."))}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Corrections.revoke(String.to_integer(id), socket.assigns.current_admin) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, gettext("Revoked; figures are being recomputed.")) |> load()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("annotate", %{"annotation" => attrs}, socket) do
    attrs =
      Map.put(
        attrs,
        "channel_id",
        attrs["scope"] == "channel" && socket.assigns.channel && socket.assigns.channel.id
      )

    case Annotations.create(attrs, socket.assigns.current_admin.id) do
      {:ok, id} ->
        Audit.log(
          socket.assigns.current_admin,
          "annotation.create",
          to_string(id),
          Map.take(attrs, ~w(text from_at to_at public))
        )

        KickTracker.Cache.clear()
        {:noreply, socket |> put_flash(:info, gettext("Annotation added.")) |> load()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_annotation", %{"id" => id}, socket) do
    Annotations.delete(String.to_integer(id))
    Audit.log(socket.assigns.current_admin, "annotation.delete", id)
    {:noreply, load(socket)}
  end

  def handle_event(
        "reprocess",
        %{"reprocess" => %{"kind" => kind, "from" => from, "to" => to}},
        socket
      )
      when kind in ["rollups", "replay"] do
    with {:ok, from} <- parse(from), {:ok, to} <- parse(to), :lt <- DateTime.compare(from, to) do
      args = %{
        "kind" => kind,
        "from" => DateTime.to_iso8601(from),
        "to" => DateTime.to_iso8601(to)
      }

      args =
        if kind == "replay" && socket.assigns.channel,
          do: Map.put(args, "channel_id", socket.assigns.channel.id),
          else: args

      {:ok, _} = Reprocess.enqueue(args)
      Audit.log(socket.assigns.current_admin, "reprocess.#{kind}", nil, args)
      {:noreply, put_flash(socket, :info, gettext("Queued; the collector runs it."))}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Give a valid range (from before to), in UTC."))}
    end
  end

  defp parse(v) do
    case DateTime.from_iso8601(v <> if(String.length(v) == 16, do: ":00Z", else: "Z")) do
      {:ok, at, _} -> {:ok, at}
      _ -> :error
    end
  end

  defp result(socket, {:ok, _}),
    do:
      {:noreply,
       socket |> put_flash(:info, gettext("Saved; figures are being recomputed.")) |> load()}

  defp result(socket, {:error, msg}), do: {:noreply, put_flash(socket, :error, msg)}

  defp merged?(corrections, stream_id),
    do:
      Enum.any?(
        corrections,
        &(&1.kind == "merge" and &1.stream_id == stream_id and is_nil(&1.revoked_at))
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:data}>
      <div phx-hook="Format" id="data-page">
        <.page_header title={gettext("Corrections")} icon="hero-wrench-screwdriver">
          <:subtitle>
            {gettext(
              "Exclude or merge streams, annotate timelines and recompute figures. Corrections are recorded on top of the raw data, never edits of it, and can be revoked."
            )}
          </:subtitle>
          <:actions>
            <form id="pick-channel" phx-change="pick" class="flex items-center gap-2">
              <.avatar
                :if={@channel}
                name={@channel.slug}
                channel_id={@channel.id}
                class="size-8 text-sm"
              />
              <label class="sr-only" for="pick-channel-select">{gettext("Channel")}</label>
              <select id="pick-channel-select" name="channel" class="select select-sm w-64">
                <option :for={c <- @channels} value={c.id} selected={@channel && @channel.id == c.id}>
                  {c.slug}
                </option>
              </select>
            </form>
          </:actions>
        </.page_header>

        <.panel :if={!@channel}>
          <.empty_state icon="hero-tv" title={gettext("No channels yet.")} />
        </.panel>

        <div
          :if={@channel}
          class="grid items-start gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]"
        >
          <.panel title={gettext("Latest streams")} icon="hero-play-circle" flush>
            <:subtitle>
              {gettext("Exclude one from every figure, or merge it into the one before it.")}
            </:subtitle>
            <div class="overflow-x-auto">
              <table id="data-streams" class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Start")}</th>
                    <th>{gettext("Duration")}</th>
                    <th class="text-end">{gettext("Peak")}</th>
                    <th class="text-end">{gettext("Correct")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={s <- @stream_rows} id={"data-stream-#{s.id}"}>
                    <td>
                      <.link
                        navigate={~p"/c/#{@channel.slug}/streams/#{s.id}"}
                        class="font-medium hover:underline"
                      ><.time at={s.started_at} /></.link>
                      <div class="mt-0.5 flex gap-1">
                        <.status_pill :if={s.excluded?} tone={:warn}>
                          {gettext("excluded")}
                        </.status_pill>
                        <.status_pill :if={merged?(@corrections, s.id)} tone={:info}>
                          {gettext("merged")}
                        </.status_pill>
                      </div>
                    </td>
                    <td class="text-sm"><.duration seconds={s.airtime_s} /></td>
                    <td class="text-end"><.num value={s.peak_viewers} /></td>
                    <td>
                      <div class="flex items-center justify-end gap-1">
                        <form :if={!s.excluded?} phx-submit="exclude" class="join">
                          <input type="hidden" name="stream" value={s.id} />
                          <input
                            name="note"
                            class="input input-xs join-item w-28"
                            placeholder={gettext("why")}
                            aria-label={gettext("Why exclude it")}
                          />
                          <button
                            class="btn btn-xs join-item gap-1"
                            data-confirm={gettext("Exclude this stream from every figure?")}
                          >
                            <.icon name="hero-no-symbol" class="size-3.5" />{gettext("Exclude")}
                          </button>
                        </form>
                        <.icon_button
                          icon="hero-arrows-pointing-in"
                          label={gettext("Merge into previous")}
                          phx-click="merge"
                          phx-value-stream={s.id}
                          data-confirm={gettext("Merge this stream into the one before it?")}
                        />
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
              <.empty_state
                :if={@stream_rows == []}
                icon="hero-play-circle"
                title={gettext("No streams recorded yet.")}
              />
            </div>
          </.panel>

          <div class="space-y-6">
            <.panel title={gettext("Corrections")} icon="hero-wrench-screwdriver">
              <p :if={@corrections == []} class="text-muted text-sm">
                {gettext("None for this channel.")}
              </p>
              <ul id="corrections" class="space-y-2 text-sm">
                <li
                  :for={c <- @corrections}
                  class={[
                    "flex flex-wrap items-center gap-2",
                    c.revoked_at && "opacity-50 line-through"
                  ]}
                >
                  <.status_pill tone={if c.kind == "exclude", do: :warn, else: :info}>
                    {c.kind}
                  </.status_pill>
                  <.time at={c.stream_at} />
                  <span :if={c.other_at} class="text-muted">← <.time at={c.other_at} /></span>
                  <span class="text-muted">{c.note}</span>
                  <span class="text-muted text-xs">{c.by}</span>
                  <span class="flex-1"></span>
                  <button
                    :if={!c.revoked_at}
                    phx-click="revoke"
                    phx-value-id={c.id}
                    class="btn btn-xs btn-ghost gap-1"
                  >
                    <.icon name="hero-arrow-uturn-left" class="size-3.5" />{gettext("Revoke")}
                  </button>
                </li>
              </ul>
            </.panel>

            <.panel title={gettext("Annotations")} icon="hero-chat-bubble-bottom-center-text">
              <:subtitle>
                {gettext("Notes on a timeline, optionally shown on public charts.")}
              </:subtitle>
              <.form
                for={%{}}
                as={:annotation}
                id="annotation-form"
                phx-submit="annotate"
                class="grid gap-2 sm:grid-cols-2"
              >
                <input
                  name="annotation[text]"
                  class="input input-sm w-full sm:col-span-2"
                  placeholder={gettext("e.g. collector outage, charity stream")}
                  required
                />
                <label class="text-muted text-xs">
                  {gettext("From (UTC)")}
                  <input
                    type="datetime-local"
                    name="annotation[from_at]"
                    class="input input-sm mt-1 w-full"
                    required
                  />
                </label>
                <label class="text-muted text-xs">
                  {gettext("To (UTC, optional)")}
                  <input
                    type="datetime-local"
                    name="annotation[to_at]"
                    class="input input-sm mt-1 w-full"
                  />
                </label>
                <select name="annotation[scope]" class="select select-sm w-full">
                  <option value="channel">{gettext("This channel")}</option>
                  <option value="all">{gettext("Every channel")}</option>
                </select>
                <label class="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    name="annotation[public]"
                    class="toggle toggle-sm toggle-primary"
                  />
                  {gettext("Show on public charts")}
                </label>
                <button class="btn btn-sm btn-primary sm:col-span-2">{gettext("Add annotation")}</button>
              </.form>
              <ul
                :if={@annotations != []}
                id="annotations"
                class="mt-4 space-y-2 border-t border-base-300 pt-3 text-sm"
              >
                <li :for={a <- @annotations} class="flex items-center gap-2">
                  <span class="text-muted whitespace-nowrap text-xs"><.time at={a.from_at} /></span>
                  <span class="flex-1">{a.text}</span>
                  <.status_pill :if={a.public} tone={:ok}>{gettext("public")}</.status_pill>
                  <.status_pill :if={is_nil(a.channel_id)}>{gettext("all channels")}</.status_pill>
                  <.icon_button
                    icon="hero-x-mark"
                    label={gettext("Delete")}
                    tone={:danger}
                    phx-click="delete_annotation"
                    phx-value-id={a.id}
                  />
                </li>
              </ul>
            </.panel>

            <.panel title={gettext("Reprocess")} icon="hero-arrow-path">
              <:subtitle>
                {gettext("Recompute derived figures, or replay stored webhook events.")}
              </:subtitle>
              <.form
                for={%{}}
                as={:reprocess}
                id="reprocess-form"
                phx-submit="reprocess"
                class="grid gap-2 sm:grid-cols-2"
              >
                <label class="text-muted text-xs">
                  {gettext("From (UTC)")}
                  <input
                    type="datetime-local"
                    name="reprocess[from]"
                    class="input input-sm mt-1 w-full"
                    required
                  />
                </label>
                <label class="text-muted text-xs">
                  {gettext("To (UTC)")}
                  <input
                    type="datetime-local"
                    name="reprocess[to]"
                    class="input input-sm mt-1 w-full"
                    required
                  />
                </label>
                <select name="reprocess[kind]" class="select select-sm w-full sm:col-span-2">
                  <option value="rollups">
                    {gettext("Recompute rollups (all channels, the range)")}
                  </option>
                  <option value="replay">
                    {gettext("Replay stored webhook events (this channel)")}
                  </option>
                </select>
                <button class="btn btn-sm sm:col-span-2" data-confirm={gettext("Queue this?")}>{gettext(
                  "Queue"
                )}</button>
              </.form>
            </.panel>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end
end
