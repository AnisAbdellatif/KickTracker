defmodule KickTrackerWeb.Admin.DeadLettersLive do
  @moduledoc """
  Dead letters (project.md §13.8): list, inspect the envelope, replay into
  the queue, or discard with a reason. Replays and discards are audited,
  the discarded envelope's identity and the reason with them. A message
  is named by its `key` (see `KickTracker.DeadLetters`), which every
  message has, with or without a message id.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, DeadLetters}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket |> assign(page_title: gettext("Dead letters"), open: nil, discarding: nil) |> load()}
  end

  defp load(socket) do
    with {:ok, messages} <- DeadLetters.list(100), {:ok, total} <- DeadLetters.count() do
      assign(socket, messages: messages, total: total, error: nil)
    else
      {:error, reason} -> assign(socket, messages: [], total: 0, error: inspect(reason))
    end
  end

  defp find(socket, key), do: Enum.find(socket.assigns.messages, &(&1.key == key))

  # The audit log names a message by its message id, or by its key when it has none.
  defp name(%{message_id: id}, _key) when is_binary(id), do: id
  defp name(_message, key), do: key

  @impl true
  def handle_event("open", %{"id" => id}, socket),
    do: {:noreply, assign(socket, open: if(socket.assigns.open == id, do: nil, else: id))}

  def handle_event("replay", %{"id" => key}, socket) when is_binary(key) do
    message = find(socket, key)

    case DeadLetters.replay(key) do
      :ok ->
        Audit.log(socket.assigns.current_admin, "dead_letter.replay", name(message, key), %{
          "key" => key,
          "copies" => message && message.copies
        })

        {:noreply,
         socket |> put_flash(:info, gettext("Replayed %{id}.", id: name(message, key))) |> load()}

      {:error, :erased} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Not replayed: it names someone whose data was removed on request, and would bring them back. Discard it instead."
           )
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not replay: %{r}", r: inspect(reason)))}
    end
  end

  def handle_event("ask_discard", %{"id" => id}, socket),
    do: {:noreply, assign(socket, discarding: id)}

  def handle_event("cancel_discard", _, socket), do: {:noreply, assign(socket, discarding: nil)}

  def handle_event("discard", %{"key" => key, "reason" => reason}, socket)
      when is_binary(key) and is_binary(reason) do
    reason = String.trim(reason)
    message = find(socket, key)

    if reason == "" do
      {:noreply, put_flash(socket, :error, gettext("Say why it is discarded."))}
    else
      case DeadLetters.discard(key) do
        :ok ->
          Audit.log(socket.assigns.current_admin, "dead_letter.discard", name(message, key), %{
            "key" => key,
            "copies" => message && message.copies,
            "reason" => reason,
            "event_type" => message && message.event_type,
            "dead_reason" => message && message.reason
          })

          {:noreply,
           socket |> assign(discarding: nil) |> put_flash(:info, gettext("Discarded.")) |> load()}

        {:error, r} ->
          {:noreply, put_flash(socket, :error, gettext("Could not discard: %{r}", r: inspect(r)))}
      end
    end
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  defp pretty(%{} = envelope) do
    envelope
    |> Map.update("body", nil, fn body ->
      case Jason.decode(body || "") do
        {:ok, decoded} -> decoded
        _ -> body
      end
    end)
    |> Jason.encode!(pretty: true)
  end

  defp pretty(nil), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:dead_letters}>
      <.header>
        {gettext("Dead letters")}
        <:subtitle>
          {gettext(
            "Messages the consumer rejected or that failed ten deliveries. Nothing is dropped silently."
          )}
        </:subtitle>
        <:actions>
          <button id="refresh" phx-click="refresh" class="btn btn-sm btn-ghost">{gettext("Refresh")}</button>
        </:actions>
      </.header>
      <p :if={@error} class="text-sm text-error">{gettext("RabbitMQ: %{e}", e: @error)}</p>
      <p :if={!@error and @messages == []} class="text-sm opacity-70">
        {gettext("The dead-letter queue is empty.")}
      </p>
      <p
        :if={!@error and @total > Enum.sum(Enum.map(@messages, & &1.copies))}
        id="dead-letters-more"
        class="text-sm opacity-70"
      >
        {gettext("%{total} messages wait; the oldest are listed.", total: @total)}
      </p>
      <ul id="dead-letters" class="space-y-2">
        <li
          :for={m <- @messages}
          id={"dl-#{m.key}"}
          class="card-surface p-4 text-sm"
        >
          <div class="flex flex-wrap items-center gap-2">
            <button phx-click="open" phx-value-id={m.key} class="link font-mono text-xs">{m.message_id ||
              gettext("no message id")}</button>
            <span class="badge badge-sm">{m.event_type || m.routing_key}</span>
            <span class="text-xs opacity-70">{m.reason} {m.count && "×#{m.count}"}</span>
            <span :if={m.copies > 1} class="badge badge-sm badge-ghost">
              {gettext("%{n} copies", n: m.copies)}
            </span>
            <span :if={m.erased != []} class="badge badge-sm badge-warning">
              {gettext("names removed data")}
            </span>
            <span class="flex-1"></span>
            <button
              :if={m.erased == []}
              phx-click="replay"
              phx-value-id={m.key}
              data-confirm={gettext("Publish it to kick.events again?")}
              class="btn btn-xs"
            >{gettext("Replay")}</button>
            <button phx-click="ask_discard" phx-value-id={m.key} class="btn btn-xs btn-ghost">{gettext(
              "Discard"
            )}</button>
          </div>
          <form
            :if={@discarding == m.key}
            id={"discard-#{m.key}"}
            phx-submit="discard"
            class="mt-2 flex gap-2"
          >
            <input type="hidden" name="key" value={m.key} />
            <input
              name="reason"
              class="input input-sm flex-1"
              placeholder={gettext("Why (kept in the audit log)")}
              required
            />
            <button class="btn btn-sm btn-error">{gettext("Discard for good")}</button>
            <button type="button" phx-click="cancel_discard" class="btn btn-sm btn-ghost">{gettext(
              "Cancel"
            )}</button>
          </form>
          <pre
            :if={@open == m.key}
            class="mt-2 max-h-96 overflow-auto rounded bg-base-200 p-2 text-xs"
          >{pretty(m.envelope) || m.payload}</pre>
        </li>
      </ul>
    </Layouts.admin>
    """
  end
end
