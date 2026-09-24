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
       pending: nil
     )
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
        <.header>
          {gettext("Export / import")}
          <:subtitle>
            {gettext(
              "Move tracked channels and their history between instances, or take them elsewhere to analyse. An export is a .zip of CSV files, one per table."
            )}
          </:subtitle>
        </.header>

        <div class="grid gap-8 lg:grid-cols-2">
          <section>
            <h2 class="font-semibold">{gettext("Export")}</h2>
            <.form for={%{}} as={:export} id="export-form" phx-submit="export" class="mt-2 space-y-3">
              <fieldset class="space-y-1 text-sm">
                <label class="flex items-center gap-2">
                  <input
                    type="radio"
                    name="export[scope]"
                    value="data"
                    class="radio radio-sm"
                    checked
                  />
                  {gettext("Channels and their history")}
                </label>
                <label class="flex items-center gap-2">
                  <input type="radio" name="export[scope]" value="channels" class="radio radio-sm" />
                  {gettext("The channel list only")}
                </label>
              </fieldset>

              <fieldset class="max-h-56 overflow-y-auto card-surface p-2 text-sm">
                <p :if={@channels == []} class="opacity-60">{gettext("No channels yet.")}</p>
                <label :for={c <- @channels} class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    name="export[channel_ids][]"
                    value={c.id}
                    class="checkbox checkbox-xs"
                    checked
                  />
                  <span>{c.slug}</span>
                  <span :if={!c.active} class="badge badge-ghost badge-xs">{gettext("paused")}</span>
                </label>
              </fieldset>

              <div class="grid grid-cols-2 gap-2">
                <label class="text-xs">{gettext("From (UTC, optional)")}<input
                  type="date"
                  name="export[from]"
                  class="input input-sm w-full"
                /></label>
                <label class="text-xs">{gettext("To (UTC, optional)")}<input
                  type="date"
                  name="export[to]"
                  class="input input-sm w-full"
                /></label>
              </div>
              <button class="btn btn-sm btn-primary">{gettext("Export")}</button>
            </.form>
          </section>

          <section>
            <h2 class="font-semibold">{gettext("Import")}</h2>
            <p class="mt-1 text-sm opacity-70">
              {gettext(
                "Adds what isn't here yet; nothing already here is changed. Channels and removal requests come along."
              )}
            </p>

            <form
              :if={!@pending}
              id="upload-form"
              phx-submit="upload"
              phx-change="validate"
              class="mt-2 space-y-2"
            >
              <.live_file_input upload={@uploads.archive} class="file-input file-input-sm w-full" />
              <div :for={entry <- @uploads.archive.entries} class="flex items-center gap-2 text-sm">
                <progress class="progress w-40" value={entry.progress} max="100" />
                <span>{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-xs btn-ghost"
                >{gettext("Cancel")}</button>
                <span :for={err <- upload_errors(@uploads.archive, entry)} class="text-error">
                  {upload_error(err)}
                </span>
              </div>
              <button class="btn btn-sm">{gettext("Upload and preview")}</button>
            </form>

            <div :if={@pending} id="import-preview" class="mt-2 card-surface p-4 text-sm">
              <% {t, p} = @pending %>
              <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
                <dt>{gettext("From")}</dt><dd>{t.manifest["site_name"]}</dd>
                <dt>{gettext("Exported")}</dt><dd>{t.manifest["exported_at"]}</dd>
                <dt>{gettext("Contents")}</dt>
                <dd>
                  {if t.manifest["scope"] == "channels",
                    do: gettext("the channel list only"),
                    else: gettext("channels and their history")}
                  <span :if={t.manifest["from"] || t.manifest["to"]} class="opacity-70">
                    ({t.manifest["from"] || "…"} – {t.manifest["to"] || "…"})
                  </span>
                </dd>
                <dt>{gettext("New channels")}</dt>
                <dd>{p.new |> Enum.map(& &1["slug"]) |> Enum.join(", ") |> blank()}</dd>
                <dt>{gettext("Already here")}</dt>
                <dd>{p.existing |> Enum.map(& &1["slug"]) |> Enum.join(", ") |> blank()}</dd>
                <dt :if={p.skipped != []}>{gettext("Not imported")}</dt>
                <dd :if={p.skipped != []}>
                  {p.skipped |> Enum.map(& &1["slug"]) |> Enum.join(", ")}
                  <span class="opacity-70">{gettext("(removed here on request)")}</span>
                </dd>
              </dl>
              <p :if={p.delete != []} id="import-deletes" class="mt-3 text-error">
                {gettext(
                  "The other instance deleted these channels on a removal request; importing deletes them here too: %{slugs}",
                  slugs: Enum.join(p.delete, ", ")
                )}
              </p>
              <table class="table table-xs mt-3">
                <tbody>
                  <tr :for={{table, n} <- Enum.sort(t.manifest["rows"])} :if={n > 0}>
                    <td class="font-mono">{table}</td><td><.num value={n} /></td>
                  </tr>
                </tbody>
              </table>
              <div class="mt-3 flex gap-2">
                <button id="confirm-import" phx-click="confirm" class="btn btn-sm btn-primary">
                  {gettext("Import")}
                </button>
                <button phx-click="discard" class="btn btn-sm btn-ghost">{gettext("Discard")}</button>
              </div>
            </div>
          </section>
        </div>

        <section class="mt-10">
          <h2 class="font-semibold">{gettext("Recent")}</h2>
          <p class="text-xs opacity-60">{gettext("Files are kept for 7 days.")}</p>
          <table id="transfers" class="table table-xs mt-2">
            <thead>
              <tr>
                <th>{gettext("When")}</th><th>{gettext("What")}</th><th>{gettext("Status")}</th><th>
                  {gettext("Size")}
                </th><th>{gettext("By")}</th><th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={t <- @transfers} id={"transfer-#{t.id}"}>
                <td><.time at={t.inserted_at} /></td>
                <td>{kind(t)}</td>
                <td>
                  <span class={["badge badge-xs", status_class(t.status)]}>{status(t.status)}</span>
                  <span :if={t.error} class="text-error">{t.error}</span>
                  <span :if={t.kind == "import" and t.summary} class="opacity-70">
                    {gettext("%{n} rows added", n: added(t.summary))}
                  </span>
                </td>
                <td>{size(t.size)}</td>
                <td class="opacity-70">{t.admin && t.admin.email}</td>
                <td>
                  <a
                    :if={t.kind == "export" and t.status == "done"}
                    href={~p"/admin/transfers/#{t.id}/download"}
                    class="link"
                  >{gettext("Download")}</a>
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.admin>
    """
  end

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

  defp status_class("done"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class(s) when s in ["queued", "running"], do: "badge-info"
  defp status_class(_), do: "badge-ghost"

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
