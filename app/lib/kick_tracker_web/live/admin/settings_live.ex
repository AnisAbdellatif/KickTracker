defmodule KickTrackerWeb.Admin.SettingsLive do
  @moduledoc """
  Settings (project.md §13.8): feature flags and the assumptions behind
  estimates. Polling cadences are not settings: they are fixed in code,
  where the rules that depend on them live (a gap cap of 75s assumes a
  60s poll).
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Settings"), settings: Settings.all())}
  end

  @impl true
  def handle_event("save", %{"settings" => %{} = params}, socket) do
    # A checkbox left unticked sends nothing; every other setting must come.
    values =
      Map.new(Settings.defaults(), fn {key, default} ->
        {key,
         if(is_boolean(default), do: Map.get(params, key, "false"), else: Map.get(params, key))}
      end)

    # All or nothing, with one audit entry (see Settings.put_all/2).
    case Settings.put_all(values, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(settings: Settings.all()) |> put_flash(:info, gettext("Saved."))}

      {:error, key, msg} ->
        {:noreply, put_flash(socket, :error, "#{label(key)}: #{msg}")}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp label("support_page_public"),
    do: gettext("Show the support page (subs, gifts, Kicks, estimated revenue) publicly")

  defp label("top_people_public"),
    do: gettext("Show top chatters and supporters by name on stream pages")

  defp label("sub_price_usd"),
    do: gettext("Assumed subscription price (USD), for the revenue estimate")

  defp label("sub_share"), do: gettext("Assumed streamer's share of a subscription (0–1)")
  defp label("kick_value_usd"), do: gettext("Assumed value of one Kick to the streamer (USD)")

  defp hint("support_page_public"),
    do: gettext("A channel's Support tab, and support figures in the data API.")

  defp hint("top_people_public"),
    do: gettext("Named on public pages; the privacy page says so while this is on.")

  defp hint("sub_price_usd"), do: gettext("Kick's price for one subscription.")
  defp hint("sub_share"), do: gettext("0.95 means the streamer keeps 95%.")
  defp hint("kick_value_usd"), do: gettext("What the streamer receives for one Kick.")

  defp unit("sub_price_usd"), do: "USD"
  defp unit("kick_value_usd"), do: "USD"
  defp unit(_), do: nil

  @impl true
  def render(assigns) do
    {flags, numbers} =
      assigns.settings |> Enum.sort() |> Enum.split_with(fn {_, v} -> is_boolean(v) end)

    assigns = assign(assigns, flags: flags, numbers: numbers)

    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:settings}>
      <.page_header title={gettext("Settings")} icon="hero-cog-6-tooth">
        <:subtitle>
          {gettext("What the public site shows, and the assumptions behind estimates.")}
        </:subtitle>
      </.page_header>

      <.form for={%{}} as={:settings} id="settings-form" phx-submit="save" class="max-w-2xl space-y-6">
        <.panel title={gettext("Public site")} icon="hero-globe-alt">
          <div class="divide-y divide-base-300">
            <label
              :for={{key, value} <- @flags}
              class="flex cursor-pointer items-start justify-between gap-4 py-3 first:pt-0 last:pb-0"
            >
              <span>
                <span class="block text-sm font-medium">{label(key)}</span>
                <span class="text-muted text-xs">{hint(key)}</span>
              </span>
              <span>
                <input type="hidden" name={"settings[#{key}]"} value="false" />
                <input
                  type="checkbox"
                  name={"settings[#{key}]"}
                  value="true"
                  checked={value}
                  class="toggle toggle-primary"
                />
              </span>
            </label>
          </div>
        </.panel>

        <.panel title={gettext("Revenue estimate")} icon="hero-banknotes">
          <:subtitle>{gettext("Shown as an estimate wherever it appears.")}</:subtitle>
          <div class="grid gap-4 sm:grid-cols-2">
            <label :for={{key, value} <- @numbers} class="block text-sm">
              <span class="font-medium">{label(key)}</span>
              <span class="input input-sm mt-1 w-full">
                <input
                  name={"settings[#{key}]"}
                  value={value}
                  inputmode="decimal"
                  class="tabular-nums"
                />
                <span :if={unit(key)} class="text-muted text-xs">{unit(key)}</span>
              </span>
              <span class="text-muted mt-1 block text-xs">{hint(key)}</span>
            </label>
          </div>
        </.panel>

        <div class="flex items-center gap-3">
          <button class="btn btn-sm btn-primary">{gettext("Save")}</button>
          <p class="text-muted text-xs">
            {gettext(
              "Polling cadences aren't settings: they are fixed in code with the rules that depend on them (viewers every 60s, subscribers every 5 minutes, followers every 15 minutes live and daily offline)."
            )}
          </p>
        </div>
      </.form>
    </Layouts.admin>
    """
  end
end
