defmodule KickTrackerWeb.Admin.SettingsLive do
  @moduledoc """
  Settings (project.md §13.8): feature flags and the assumptions behind
  estimates. Polling cadences are not settings: they are fixed in code,
  where the rules that depend on them live (a gap cap of 75s assumes a
  60s poll).
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Audit, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Settings"), settings: Settings.all())}
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    results =
      for {key, default} <- Settings.defaults() do
        value =
          if is_boolean(default), do: Map.get(params, key, "false"), else: Map.get(params, key)

        {key, Settings.put(key, value)}
      end

    case Enum.find(results, &match?({_, {:error, _}}, &1)) do
      nil ->
        Audit.log(
          socket.assigns.current_admin,
          "settings.update",
          nil,
          Map.new(results, fn {k, {:ok, v}} -> {k, v} end)
        )

        {:noreply,
         socket |> assign(settings: Settings.all()) |> put_flash(:info, gettext("Saved."))}

      {key, {:error, msg}} ->
        {:noreply, put_flash(socket, :error, "#{key}: #{msg}")}
    end
  end

  defp label("support_page_public"),
    do: gettext("Show the support page (subs, gifts, Kicks, estimated revenue) publicly")

  defp label("top_people_public"),
    do: gettext("Show top chatters and supporters by name on stream pages")

  defp label("sub_price_usd"),
    do: gettext("Assumed subscription price (USD), for the revenue estimate")

  defp label("sub_share"), do: gettext("Assumed streamer's share of a subscription (0–1)")
  defp label("kick_value_usd"), do: gettext("Assumed value of one Kick to the streamer (USD)")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:settings}>
      <.header>{gettext("Settings")}</.header>
      <.form for={%{}} as={:settings} id="settings-form" phx-submit="save" class="max-w-xl space-y-3">
        <%= for {key, value} <- Enum.sort(@settings) do %>
          <%= if is_boolean(value) do %>
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name={"settings[#{key}]"} value="false" />
              <input
                type="checkbox"
                name={"settings[#{key}]"}
                value="true"
                checked={value}
                class="checkbox checkbox-sm"
              />
              {label(key)}
            </label>
          <% else %>
            <label class="block text-sm">
              {label(key)}
              <input
                name={"settings[#{key}]"}
                value={value}
                inputmode="decimal"
                class="input input-sm mt-1 w-40 block"
              />
            </label>
          <% end %>
        <% end %>
        <button class="btn btn-sm btn-primary">{gettext("Save")}</button>
      </.form>
      <p class="mt-6 max-w-xl text-xs opacity-70">
        {gettext(
          "Polling cadences aren't settings: they are fixed in code with the rules that depend on them (viewers every 60s, subscribers every 5 minutes, followers every 15 minutes live and daily offline)."
        )}
      </p>
    </Layouts.admin>
    """
  end
end
