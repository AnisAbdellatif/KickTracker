defmodule KickTrackerWeb.Admin.TransferLive do
  @moduledoc """
  Export and import (project.md §13.8): download tracked channels, alone
  or with their history, as a `.zip` of CSVs; upload one from another
  instance, see what it would do, and merge it. The collector does the
  work (`Workers.Transfer`); this page queues it and follows it.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Channels, Transfers}

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Export / import"),
       channels: Channels.list_all(),
       pending: nil,
       export_q: ""
     )
     |> then(&assign(&1, export_ids: MapSet.new(&1.assigns.channels, fn c -> c.id end)))
     |> assign(transfers: Transfers.list())
     |> allow_upload(:archive,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: Application.fetch_env!(:kick_tracker, :transfer_max_upload)
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    if Enum.any?(socket.assigns.transfers, &(&1.status in ["queued", "running"])),
      do: {:noreply, assign(socket, transfers: Transfers.list())},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("export", %{"export" => params}, socket) do
    ids =
      for id <- List.wrap(params["channel_ids"]), {n, ""} <- [Integer.parse(id)], do: n

    with [_ | _] <- ids,
         {:ok, from} <- day(params["from"], ~T[00:00:00]),
         {:ok, to} <- day(params["to"], ~T[23:59:59.999999]) do
      options = %{
        "scope" => if(params["scope"] == "channels", do: "channels", else: "data"),
        "channel_ids" => ids,
        "from" => from && DateTime.to_iso8601(from),
        "to" => to && DateTime.to_iso8601(to)
      }

      {:ok, _} = Transfers.request_export(socket.assigns.current_admin, options)

      {:noreply,
       socket
       |> assign(transfers: Transfers.list())
       |> put_flash(:info, gettext("Export queued; it appears below when ready."))}
    else
      [] -> {:noreply, put_flash(socket, :error, gettext("Pick at least one channel."))}
      :error -> {:noreply, put_flash(socket, :error, gettext("Dates are YYYY-MM-DD."))}
    end
  end

  # The export form as it is edited: which channels are ticked, and the
  # search over them (non-matching ones are hidden, not unticked).
  def handle_event("export_change", %{"export" => params}, socket) do
    ids = for id <- List.wrap(params["channel_ids"]), {n, ""} <- [Integer.parse(id)], do: n

    {:noreply,
     assign(socket, export_ids: MapSet.new(ids), export_q: params["q"] || socket.assigns.export_q)}
  end

  # "All" or "None", for the channels the search shows.
  def handle_event("export_select", %{"to" => to}, socket) when to in ~w(all none) do
    shown =
      socket.assigns.channels
      |> Enum.filter(&matches?(&1, socket.assigns.export_q))
      |> Enum.map(& &1.id)

    ids =
      if to == "all",
        do: MapSet.union(socket.assigns.export_ids, MapSet.new(shown)),
        else: MapSet.difference(socket.assigns.export_ids, MapSet.new(shown))

    {:noreply, assign(socket, export_ids: ids)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    admin = socket.assigns.current_admin

    result =
      consume_uploaded_entries(socket, :archive, fn %{path: path}, _entry ->
        {:ok, Transfers.upload_import(admin, path)}
      end)

    case result do
      [{:ok, t}] ->
        Audit.log(admin, "transfer.upload", "#{t.id}", %{"size" => t.size})

        {:noreply,
         assign(socket, pending: {t, Transfers.preview(t)}, transfers: Transfers.list())}

      [{:error, t}] ->
        Audit.log(admin, "transfer.upload", "#{t.id}", %{"size" => t.size, "error" => t.error})

        {:noreply,
         socket
         |> assign(transfers: Transfers.list())
         |> put_flash(:error, gettext("Can't import this file: %{reason}", reason: t.error))}

      [] ->
        {:noreply, put_flash(socket, :error, gettext("Choose a .zip export first."))}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :archive, ref)}

  def handle_event("confirm", _params, socket) do
    {t, _} = socket.assigns.pending
    {:ok, _} = Transfers.confirm_import(socket.assigns.current_admin, Transfers.get!(t.id))

    {:noreply,
     socket
     |> assign(pending: nil, transfers: Transfers.list())
     |> put_flash(:info, gettext("Import queued; the collector runs it now."))}
  end

  def handle_event("discard", _params, socket) do
    {t, _} = socket.assigns.pending
    Transfers.cancel_import(Transfers.get!(t.id))
    Audit.log(socket.assigns.current_admin, "transfer.discard", "#{t.id}")
    {:noreply, assign(socket, pending: nil, transfers: Transfers.list())}
  end

  defp day(blank, _time) when blank in [nil, ""], do: {:ok, nil}

  defp day(date, time) do
    case Date.from_iso8601(date) do
      {:ok, d} -> {:ok, DateTime.new!(d, time, "Etc/UTC")}
      _ -> :error
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:transfer}>
      <div phx-hook="Format" id="transfer-page">
        <.page_header title={gettext("Export / import")} icon="hero-arrows-right-left">
          <:subtitle>
            {gettext(
              "Move tracked channels and their history between instances, or take them elsewhere to analyse. An export is a .zip of CSV files, one per table."
            )}
          </:subtitle>
        </.page_header>

        <div class="grid items-start gap-6 lg:grid-cols-2">
          <.panel title={gettext("Export")} icon="hero-arrow-down-tray">
            <.form
              for={%{}}
              as={:export}
              id="export-form"
              phx-submit="export"
              phx-change="export_change"
              class="space-y-4"
            >
              <fieldset class="grid gap-2 sm:grid-cols-2">
                <label class="export-choice">
                  <input
                    type="radio"
                    name="export[scope]"
                    value="data"
                    class="radio radio-sm radio-primary"
                    checked
                  />
                  <span>
                    <span class="block font-medium">{gettext("Channels and their history")}</span>
                    <span class="text-muted text-xs">{gettext(
                      "Everything collected, for a range or all of it"
                    )}</span>
                  </span>
                </label>
                <label class="export-choice">
                  <input
                    type="radio"
                    name="export[scope]"
                    value="channels"
                    class="radio radio-sm radio-primary"
                  />
                  <span>
                    <span class="block font-medium">{gettext("The channel list only")}</span>
                    <span class="text-muted text-xs">{gettext("To track the same channels elsewhere")}</span>
                  </span>
                </label>
              </fieldset>

              <div>
                <div class="mb-2 flex flex-wrap items-center gap-2">
                  <p class="text-sm font-medium">{gettext("Channels")}</p>
                  <span id="export-count" class="text-muted text-xs">
                    {gettext("%{n} of %{all} selected",
                      n: MapSet.size(@export_ids),
                      all: length(@channels)
                    )}
                  </span>
                  <span class="flex-1"></span>
                  <button
                    type="button"
                    phx-click="export_select"
                    phx-value-to="all"
                    class="btn btn-xs btn-ghost"
                  >
                    {gettext("All")}
                  </button>
                  <button
                    type="button"
                    phx-click="export_select"
                    phx-value-to="none"
                    class="btn btn-xs btn-ghost"
                  >
                    {gettext("None")}
                  </button>
                </div>
                <label class="input input-sm mb-2 w-full">
                  <.icon name="hero-magnifying-glass" class="text-muted size-4" />
                  <input
                    type="search"
                    name="export[q]"
                    value={@export_q}
                    placeholder={gettext("Search channels")}
                    phx-debounce="150"
                    autocomplete="off"
                  />
                </label>
                <div class="scroll-panel inset-well max-h-64 overflow-y-auto p-2">
                  <p :if={@channels == []} class="text-muted p-2 text-sm">
                    {gettext("No channels yet.")}
                  </p>
                  <label
                    :for={c <- @channels}
                    class={[
                      "flex cursor-pointer items-center gap-2 rounded-[var(--radius-field)] px-2 py-1 text-sm hover:bg-[var(--surface-hover)]",
                      !matches?(c, @export_q) && "hidden"
                    ]}
                  >
                    <input
                      type="checkbox"
                      name="export[channel_ids][]"
                      value={c.id}
                      class="checkbox checkbox-xs checkbox-primary"
                      checked={MapSet.member?(@export_ids, c.id)}
                    />
                    <span class="flex-1 truncate">{c.slug}</span>
                    <.status_pill :if={!c.active}>{gettext("paused")}</.status_pill>
                  </label>
                </div>
              </div>

              <div class="grid grid-cols-2 gap-2">
                <label class="text-muted text-xs">
                  {gettext("From (UTC, optional)")}
                  <input type="date" name="export[from]" class="input input-sm mt-1 w-full" />
                </label>
                <label class="text-muted text-xs">
                  {gettext("To (UTC, optional)")}
                  <input type="date" name="export[to]" class="input input-sm mt-1 w-full" />
                </label>
              </div>
              <button class="btn btn-sm btn-primary gap-1">
                <.icon name="hero-arrow-down-tray" class="size-4" />{gettext("Export")}
              </button>
            </.form>
          </.panel>

          <.panel title={gettext("Import")} icon="hero-arrow-up-tray">
            <:subtitle>
              {gettext(
                "Adds what isn't here yet; nothing already here is changed. Channels and removal requests come along."
              )}
            </:subtitle>

            <form
              :if={!@pending}
              id="upload-form"
              phx-submit="upload"
              phx-change="validate"
              class="space-y-3"
            >
              <label
                phx-drop-target={@uploads.archive.ref}
                class="drop-zone flex cursor-pointer flex-col items-center gap-2 p-6 text-center"
              >
                <.icon name="hero-arrow-up-tray" class="text-muted size-6" />
                <span class="text-sm">{gettext("Drop an export here, or choose a .zip")}</span>
                <.live_file_input
                  upload={@uploads.archive}
                  class="file-input file-input-sm w-full max-w-xs"
                />
              </label>
              <div
                :for={entry <- @uploads.archive.entries}
                class="flex flex-wrap items-center gap-2 text-sm"
              >
                <.icon name="hero-document" class="text-muted size-4" />
                <span class="truncate">{entry.client_name}</span>
                <progress class="progress progress-primary w-32" value={entry.progress} max="100" />
                <button
                  type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-xs btn-ghost"
                >
                  {gettext("Cancel")}
                </button>
                <span :for={err <- upload_errors(@uploads.archive, entry)} class="text-error">
                  {upload_error(err)}
                </span>
              </div>
              <button class="btn btn-sm gap-1">
                <.icon name="hero-eye" class="size-4" />{gettext("Upload and preview")}
              </button>
            </form>

            <div :if={@pending} id="import-preview" class="text-sm">
              <% {t, p} = @pending %>
              <dl class="kv-list">
                <dt>{gettext("From")}</dt><dd>{t.manifest["site_name"]}</dd>
                <dt>{gettext("Exported")}</dt><dd>{t.manifest["exported_at"]}</dd>
                <dt>{gettext("Contents")}</dt>
                <dd>
                  {if t.manifest["scope"] == "channels",
                    do: gettext("the channel list only"),
                    else: gettext("channels and their history")}
                  <span :if={t.manifest["from"] || t.manifest["to"]} class="text-muted">
                    ({t.manifest["from"] || "…"} – {t.manifest["to"] || "…"})
                  </span>
                </dd>
              </dl>
              <div class="mt-3 space-y-2">
                <p>
                  <span class="text-muted">{gettext("New channels")}:</span> {p.new
                  |> Enum.map(& &1["slug"])
                  |> Enum.join(", ")
                  |> blank()}
                </p>
                <p>
                  <span class="text-muted">{gettext("Already here")}:</span> {p.existing
                  |> Enum.map(& &1["slug"])
                  |> Enum.join(", ")
                  |> blank()}
                </p>
                <p :if={p.skipped != []}>
                  <span class="text-muted">{gettext("Not imported")}:</span>
                  {p.skipped |> Enum.map(& &1["slug"]) |> Enum.join(", ")}
                  <span class="text-muted">{gettext("(removed here on request)")}</span>
                </p>
              </div>
              <p :if={p.delete != []} id="import-deletes" class="alert alert-error mt-3 text-sm">
                {gettext(
                  "The other instance deleted these channels on a removal request; importing deletes them here too: %{slugs}",
                  slugs: Enum.join(p.delete, ", ")
                )}
              </p>
              <details class="mt-3">
                <summary class="text-muted cursor-pointer text-xs">
                  {gettext("Rows in the file")}
                </summary>
                <dl class="kv-list inset-well mt-2 p-3 text-xs">
                  <%= for {table, n} <- Enum.sort(t.manifest["rows"]), n > 0 do %>
                    <dt class="font-mono">{table}</dt><dd><.num value={n} /></dd>
                  <% end %>
                </dl>
              </details>
              <div class="mt-4 flex gap-2">
                <button id="confirm-import" phx-click="confirm" class="btn btn-sm btn-primary">{gettext(
                  "Import"
                )}</button>
                <button phx-click="discard" class="btn btn-sm btn-ghost">{gettext("Discard")}</button>
              </div>
            </div>
          </.panel>
        </div>

        <.panel title={gettext("Recent")} icon="hero-clock" class="mt-6" flush>
          <:subtitle>{gettext("Files are kept for 7 days.")}</:subtitle>
          <div class="overflow-x-auto">
            <table id="transfers" class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("When")}</th>
                  <th>{gettext("What")}</th>
                  <th>{gettext("Status")}</th>
                  <th class="text-end">{gettext("Size")}</th>
                  <th>{gettext("By")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- @transfers} id={"transfer-#{t.id}"}>
                  <td class="whitespace-nowrap text-sm"><.time at={t.inserted_at} /></td>
                  <td class="text-sm">{kind(t)}</td>
                  <td>
                    <.status_pill tone={status_tone(t.status)}>{status(t.status)}</.status_pill>
                    <span :if={t.error} class="ms-1 text-xs text-error">{t.error}</span>
                    <span :if={t.kind == "import" and t.summary} class="text-muted ms-1 text-xs">
                      {gettext("%{n} rows added", n: added(t.summary))}
                    </span>
                  </td>
                  <td class="text-end text-sm tabular-nums">{size(t.size)}</td>
                  <td class="text-muted text-sm">{t.admin && t.admin.email}</td>
                  <td class="text-end">
                    <a
                      :if={t.kind == "export" and t.status == "done"}
                      href={~p"/admin/transfers/#{t.id}/download"}
                      class="btn btn-xs btn-ghost gap-1"
                    >
                      <.icon name="hero-arrow-down-tray" class="size-3.5" />{gettext("Download")}
                    </a>
                  </td>
                </tr>
              </tbody>
            </table>
            <.empty_state
              :if={@transfers == []}
              icon="hero-clock"
              title={gettext("No exports or imports yet.")}
            />
          </div>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end

  defp matches?(_channel, q) when q in [nil, ""], do: true

  defp matches?(channel, q),
    do: String.contains?(String.downcase(channel.slug), String.downcase(String.trim(q)))

  defp blank(""), do: "–"
  defp blank(s), do: s

  defp kind(%{kind: "export", options: %{"scope" => "channels"}}),
    do: gettext("Export: channel list")

  defp kind(%{kind: "export"}), do: gettext("Export: channels and history")
  defp kind(%{kind: "import"}), do: gettext("Import")

  defp status("uploaded"), do: gettext("awaiting confirmation")
  defp status("queued"), do: gettext("queued")
  defp status("running"), do: gettext("running")
  defp status("done"), do: gettext("done")
  defp status("failed"), do: gettext("failed")
  defp status("expired"), do: gettext("expired")

  defp status_tone("done"), do: :ok
  defp status_tone("failed"), do: :error
  defp status_tone(s) when s in ["queued", "running"], do: :info
  defp status_tone(_), do: :neutral

  defp added(summary),
    do: summary["tables"] |> Map.values() |> Enum.map(& &1["added"]) |> Enum.sum()

  defp size(nil), do: "–"
  defp size(b) when b < 1_000_000, do: "#{Float.round(b / 1_000, 1)} kB"
  defp size(b) when b < 1_000_000_000, do: "#{Float.round(b / 1_000_000, 1)} MB"
  defp size(b), do: "#{Float.round(b / 1_000_000_000, 2)} GB"

  defp upload_error(:too_large), do: gettext("too large")
  defp upload_error(:not_accepted), do: gettext("not a .zip")
  defp upload_error(:too_many_files), do: gettext("one file at a time")
  defp upload_error(_), do: gettext("upload failed")
end
