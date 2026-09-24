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
    {:ok, assign(socket, page_title: gettext("Data"), channels: Channels.list_all())}
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
        <.header>
          {gettext("Data")}
          <:subtitle>
            {gettext("Corrections are recorded on top of the raw data, never edits of it.")}
          </:subtitle>
        </.header>

        <form id="pick-channel" phx-change="pick" class="mb-4">
          <select name="channel" class="select select-sm w-64">
            <option :for={c <- @channels} value={c.id} selected={@channel && @channel.id == c.id}>
              {c.slug}
            </option>
          </select>
        </form>

        <div :if={@channel} class="grid gap-6 lg:grid-cols-2">
          <section>
            <h2 class="font-semibold">{gettext("Streams")}</h2>
            <table id="data-streams" class="table table-xs mt-2">
              <thead>
                <tr>
                  <th>{gettext("Start")}</th><th>{gettext("Duration")}</th><th>{gettext("Peak")}</th><th>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={s <- @stream_rows} id={"data-stream-#{s.id}"}>
                  <td>
                    <.link navigate={~p"/c/#{@channel.slug}/streams/#{s.id}"} class="link"><.time at={
                      s.started_at
                    } /></.link>
                    <span :if={s.excluded?} class="badge badge-warning badge-xs">{gettext("excluded")}</span>
                    <span :if={merged?(@corrections, s.id)} class="badge badge-info badge-xs">{gettext(
                      "merged"
                    )}</span>
                  </td>
                  <td><.duration seconds={s.airtime_s} /></td>
                  <td><.num value={s.peak_viewers} /></td>
                  <td class="whitespace-nowrap">
                    <form :if={!s.excluded?} phx-submit="exclude" class="inline-flex gap-1">
                      <input type="hidden" name="stream" value={s.id} />
                      <input name="note" class="input input-xs w-28" placeholder={gettext("why")} />
                      <button
                        class="btn btn-xs"
                        data-confirm={gettext("Exclude this stream from every figure?")}
                      >{gettext("Exclude")}</button>
                    </form>
                    <button
                      phx-click="merge"
                      phx-value-stream={s.id}
                      class="btn btn-xs btn-ghost"
                      data-confirm={gettext("Merge this stream into the one before it?")}
                    >
                      {gettext("Merge into previous")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>

          <section>
            <h2 class="font-semibold">{gettext("Corrections")}</h2>
            <p :if={@corrections == []} class="text-sm opacity-60">{gettext("None.")}</p>
            <ul id="corrections" class="mt-2 space-y-1 text-sm">
              <li
                :for={c <- @corrections}
                class={[
                  "flex flex-wrap items-center gap-2",
                  c.revoked_at && "opacity-50 line-through"
                ]}
              >
                <span class="badge badge-sm">{c.kind}</span>
                <.time at={c.stream_at} />
                <span :if={c.other_at}>← <.time at={c.other_at} /></span>
                <span class="opacity-70">{c.note}</span>
                <span class="text-xs opacity-50">{c.by}</span>
                <button
                  :if={!c.revoked_at}
                  phx-click="revoke"
                  phx-value-id={c.id}
                  class="btn btn-xs btn-ghost"
                >{gettext("Revoke")}</button>
              </li>
            </ul>

            <h2 class="mt-8 font-semibold">{gettext("Annotations")}</h2>
            <.form
              for={%{}}
              as={:annotation}
              id="annotation-form"
              phx-submit="annotate"
              class="mt-2 grid gap-2 sm:grid-cols-2"
            >
              <input
                name="annotation[text]"
                class="input input-sm sm:col-span-2"
                placeholder={gettext("e.g. collector outage, charity stream")}
                required
              />
              <label class="text-xs">{gettext("From (UTC)")}<input
                type="datetime-local"
                name="annotation[from_at]"
                class="input input-sm w-full"
                required
              /></label>
              <label class="text-xs">{gettext("To (UTC, optional)")}<input
                type="datetime-local"
                name="annotation[to_at]"
                class="input input-sm w-full"
              /></label>
              <select name="annotation[scope]" class="select select-sm">
                <option value="channel">{gettext("This channel")}</option>
                <option value="all">{gettext("Every channel")}</option>
              </select>
              <label class="flex items-center gap-2 text-sm"><input
                type="checkbox"
                name="annotation[public]"
                class="checkbox checkbox-sm"
              /> {gettext("Show on public charts")}</label>
              <button class="btn btn-sm sm:col-span-2">{gettext("Add annotation")}</button>
            </.form>
            <ul id="annotations" class="mt-3 space-y-1 text-sm">
              <li :for={a <- @annotations} class="flex gap-2">
                <.time at={a.from_at} />
                <span class="flex-1">{a.text}</span>
                <span :if={a.public} class="badge badge-xs">{gettext("public")}</span>
                <span :if={is_nil(a.channel_id)} class="badge badge-xs badge-ghost">{gettext(
                  "all channels"
                )}</span>
                <button phx-click="delete_annotation" phx-value-id={a.id} class="btn btn-xs btn-ghost">×</button>
              </li>
            </ul>

            <h2 class="mt-8 font-semibold">{gettext("Reprocess")}</h2>
            <.form
              for={%{}}
              as={:reprocess}
              id="reprocess-form"
              phx-submit="reprocess"
              class="mt-2 grid gap-2 sm:grid-cols-2"
            >
              <label class="text-xs">{gettext("From (UTC)")}<input
                type="datetime-local"
                name="reprocess[from]"
                class="input input-sm w-full"
                required
              /></label>
              <label class="text-xs">{gettext("To (UTC)")}<input
                type="datetime-local"
                name="reprocess[to]"
                class="input input-sm w-full"
                required
              /></label>
              <select name="reprocess[kind]" class="select select-sm sm:col-span-2">
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
          </section>
        </div>
      </div>
    </Layouts.admin>
    """
  end
end
