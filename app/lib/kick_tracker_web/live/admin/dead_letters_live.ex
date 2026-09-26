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
      <.page_header title={gettext("Dead letters")} icon="hero-inbox-stack">
        <:subtitle>
          {gettext(
            "Webhook messages the consumer rejected, or that failed ten deliveries. Nothing is dropped silently: each waits here to be replayed or discarded with a reason."
          )}
        </:subtitle>
        <:actions>
          <button id="refresh" phx-click="refresh" class="btn btn-sm btn-ghost gap-1">
            <.icon name="hero-arrow-path" class="size-4" />{gettext("Refresh")}
          </button>
        </:actions>
      </.page_header>

      <.panel :if={@error} class="mb-6 border-error/50">
        <div class="flex items-start gap-3">
          <span class="icon-tile text-error"><.icon name="hero-exclamation-triangle" class="size-5" /></span>
          <div>
            <p class="font-medium">{gettext("RabbitMQ didn't answer.")}</p>
            <p class="text-muted mt-1 break-all text-xs">{@error}</p>
          </div>
        </div>
      </.panel>

      <.panel :if={!@error and @messages == []}>
        <.empty_state icon="hero-inbox" title={gettext("The dead-letter queue is empty.")}>
          {gettext("Every webhook received so far was handled.")}
        </.empty_state>
      </.panel>

      <.panel
        :if={@messages != []}
        title={ngettext("1 message waiting", "%{count} messages waiting", @total)}
        icon="hero-inbox-stack"
        flush
      >
        <:subtitle :if={@total > Enum.sum(Enum.map(@messages, & &1.copies))}>
          <span id="dead-letters-more">
            {gettext("%{total} messages wait; the oldest are listed.", total: @total)}
          </span>
        </:subtitle>
        <ul id="dead-letters" class="divide-y divide-base-300">
          <li :for={m <- @messages} id={"dl-#{m.key}"} class="px-4 py-3 text-sm">
            <div class="flex flex-wrap items-center gap-2">
              <button
                phx-click="open"
                phx-value-id={m.key}
                class="inline-flex items-center gap-1 font-mono text-xs hover:text-primary"
                aria-expanded={to_string(@open == m.key)}
              >
                <.icon
                  name="hero-chevron-right"
                  class={["size-3.5 transition", @open == m.key && "rotate-90"]}
                />
                {m.message_id || gettext("no message id")}
              </button>
              <.status_pill tone={:info}>{m.event_type || m.routing_key}</.status_pill>
              <.status_pill tone={:error}>{m.reason}{m.count && " ×#{m.count}"}</.status_pill>
              <.status_pill :if={m.copies > 1}>{gettext("%{n} copies", n: m.copies)}</.status_pill>
              <.status_pill :if={m.erased != []} tone={:warn}>
                {gettext("names removed data")}
              </.status_pill>
              <span class="flex-1"></span>
              <button
                :if={m.erased == []}
                phx-click="replay"
                phx-value-id={m.key}
                data-confirm={gettext("Publish it to kick.events again?")}
                class="btn btn-sm btn-ghost gap-1"
              >
                <.icon name="hero-arrow-uturn-right" class="size-4" />{gettext("Replay")}
              </button>
              <button
                phx-click="ask_discard"
                phx-value-id={m.key}
                class="btn btn-sm btn-ghost gap-1 text-error"
              >
                <.icon name="hero-trash" class="size-4" />{gettext("Discard")}
              </button>
            </div>
            <form
              :if={@discarding == m.key}
              id={"discard-#{m.key}"}
              phx-submit="discard"
              class="inset-well mt-3 flex flex-wrap gap-2 p-3"
            >
              <input type="hidden" name="key" value={m.key} />
              <input
                name="reason"
                class="input input-sm min-w-56 flex-1"
                placeholder={gettext("Why (kept in the audit log)")}
                phx-mounted={Phoenix.LiveView.JS.focus()}
                required
              />
              <button class="btn btn-sm btn-error">{gettext("Discard for good")}</button>
              <button type="button" phx-click="cancel_discard" class="btn btn-sm btn-ghost">
                {gettext("Cancel")}
              </button>
            </form>
            <pre
              :if={@open == m.key}
              class="scroll-panel inset-well mt-3 max-h-96 overflow-auto p-3 text-xs"
            >{pretty(m.envelope) || m.payload}</pre>
          </li>
        </ul>
      </.panel>
    </Layouts.admin>
    """
  end
end
