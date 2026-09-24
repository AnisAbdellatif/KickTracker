defmodule KickTrackerWeb.Admin.DeadLettersLive do
  @moduledoc """
  Dead letters (project.md §13.8): list, inspect the envelope, replay into
  the queue, or discard with a reason. Replays and discards are audited,
  the discarded envelope's identity and the reason with them.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, DeadLetters}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket |> assign(page_title: gettext("Dead letters"), open: nil, discarding: nil) |> load()}
  end

  defp load(socket) do
    case DeadLetters.list(100) do
      {:ok, messages} -> assign(socket, messages: messages, error: nil)
      {:error, reason} -> assign(socket, messages: [], error: inspect(reason))
    end
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket),
    do: {:noreply, assign(socket, open: if(socket.assigns.open == id, do: nil, else: id))}

  def handle_event("replay", %{"id" => id}, socket) do
    case DeadLetters.replay(id) do
      :ok ->
        Audit.log(socket.assigns.current_admin, "dead_letter.replay", id)
        {:noreply, socket |> put_flash(:info, gettext("Replayed %{id}.", id: id)) |> load()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not replay: %{r}", r: inspect(reason)))}
    end
  end

  def handle_event("ask_discard", %{"id" => id}, socket),
    do: {:noreply, assign(socket, discarding: id)}

  def handle_event("cancel_discard", _, socket), do: {:noreply, assign(socket, discarding: nil)}

  def handle_event("discard", %{"message_id" => id, "reason" => reason}, socket) do
    reason = String.trim(reason)
    message = Enum.find(socket.assigns.messages, &(&1.message_id == id))

    cond do
      reason == "" ->
        {:noreply, put_flash(socket, :error, gettext("Say why it is discarded."))}

      true ->
        case DeadLetters.discard(id) do
          :ok ->
            Audit.log(socket.assigns.current_admin, "dead_letter.discard", id, %{
              "reason" => reason,
              "event_type" => message && message.event_type,
              "dead_reason" => message && message.reason
            })

            {:noreply,
             socket
             |> assign(discarding: nil)
             |> put_flash(:info, gettext("Discarded."))
             |> load()}

          {:error, r} ->
            {:noreply,
             put_flash(socket, :error, gettext("Could not discard: %{r}", r: inspect(r)))}
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
      <ul id="dead-letters" class="space-y-2">
        <li
          :for={m <- @messages}
          id={"dl-#{m.message_id}"}
          class="rounded-box border border-base-300 p-3 text-sm"
        >
          <div class="flex flex-wrap items-center gap-2">
            <button phx-click="open" phx-value-id={m.message_id} class="link font-mono text-xs">{m.message_id ||
              "?"}</button>
            <span class="badge badge-sm">{m.event_type || m.routing_key}</span>
            <span class="text-xs opacity-70">{m.reason} {m.count && "×#{m.count}"}</span>
            <span class="flex-1"></span>
            <button
              phx-click="replay"
              phx-value-id={m.message_id}
              data-confirm={gettext("Publish it to kick.events again?")}
              class="btn btn-xs"
            >{gettext("Replay")}</button>
            <button phx-click="ask_discard" phx-value-id={m.message_id} class="btn btn-xs btn-ghost">{gettext(
              "Discard"
            )}</button>
          </div>
          <form
            :if={@discarding == m.message_id}
            id={"discard-#{m.message_id}"}
            phx-submit="discard"
            class="mt-2 flex gap-2"
          >
            <input type="hidden" name="message_id" value={m.message_id} />
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
            :if={@open == m.message_id}
            class="mt-2 max-h-96 overflow-auto rounded bg-base-200 p-2 text-xs"
          >{pretty(m.envelope) || m.payload}</pre>
        </li>
      </ul>
    </Layouts.admin>
    """
  end
end
