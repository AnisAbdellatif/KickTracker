defmodule KickTrackerWeb.Admin.SubscriptionsLive do
  @moduledoc """
  Kick's webhook subscriptions against what they should be (project.md
  §13.8): per active channel and event type, and the extra ones a sync
  would remove. "Resync" queues `SubscriptionSync` on the collector.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Channels}
  alias KickTracker.Kick.API
  alias KickTracker.Workers.SubscriptionSync

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Subscriptions")) |> load()}
  end

  defp load(socket) do
    channels = Channels.list_active()
    wanted = SubscriptionSync.events()

    case API.subscriptions() do
      {:ok, subs} ->
        have = MapSet.new(subs, &{&1["broadcaster_user_id"], &1["event"]})
        {create, delete} = SubscriptionSync.plan(channels, subs)

        assign(socket,
          error: nil,
          channels: channels,
          wanted: wanted,
          have: have,
          missing: Enum.sum_by(create, fn {_, events} -> length(events) end),
          extra: length(delete),
          total: length(subs)
        )

      {:error, reason} ->
        assign(socket,
          error: inspect(reason),
          channels: channels,
          wanted: wanted,
          have: MapSet.new(),
          missing: nil,
          extra: nil,
          total: nil
        )
    end
  catch
    :exit, reason ->
      assign(socket,
        error: inspect(reason),
        channels: [],
        wanted: [],
        have: MapSet.new(),
        missing: nil,
        extra: nil,
        total: nil
      )
  end

  @impl true
  def handle_event("resync", _params, socket) do
    {:ok, _} = SubscriptionSync.enqueue()
    Audit.log(socket.assigns.current_admin, "subscriptions.resync")

    {:noreply,
     put_flash(socket, :info, gettext("Resync queued; the collector runs it within seconds."))}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:subscriptions}>
      <.header>
        {gettext("Webhook subscriptions")}
        <:subtitle>
          {gettext(
            "Where deliveries go is set once in the Kick app's settings; this is who we subscribed to."
          )}
        </:subtitle>
        <:actions>
          <button id="refresh" phx-click="refresh" class="btn btn-sm btn-ghost">{gettext("Refresh")}</button>
          <button id="resync" phx-click="resync" class="btn btn-sm btn-primary">{gettext("Resync now")}</button>
        </:actions>
      </.header>
      <p :if={@error} class="text-error text-sm">{gettext("Kick didn't answer: %{e}", e: @error)}</p>
      <p :if={@total} class="text-sm">
        {gettext("%{total} subscriptions at Kick; %{missing} missing, %{extra} to remove.",
          total: @total,
          missing: @missing,
          extra: @extra
        )}
      </p>
      <div class="mt-3 overflow-x-auto">
        <table id="subscriptions" class="table table-xs">
          <thead>
            <tr>
              <th>{gettext("Channel")}</th>
              <th :for={e <- @wanted} class="text-center">{e}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @channels}>
              <td>{c.slug}</td>
              <td :for={e <- @wanted} class="text-center">
                <span :if={MapSet.member?(@have, {c.kick_user_id, e})} class="text-success">✓</span>
                <span :if={!MapSet.member?(@have, {c.kick_user_id, e})} class="text-error font-bold">✗</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.admin>
    """
  end
end
