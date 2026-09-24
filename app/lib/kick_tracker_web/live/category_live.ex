defmodule KickTrackerWeb.CategoryLive do
  @moduledoc "A category (project.md §13.2): the tracked channels streaming it, ranked by hours watched."

  use KickTrackerWeb, :live_view

  alias KickTracker.{Cache, Reports}
  alias KickTrackerWeb.{PageParams, Period}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Reports.category_by_slug(slug) do
      nil ->
        raise KickTrackerWeb.NotFoundError, "no category #{slug}"

      category ->
        {:ok,
         assign(socket,
           category: category,
           page_title: category.name,
           page_description:
             gettext("The tracked channels streaming %{category}, ranked by hours watched.",
               category: category.name
             )
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = PageParams.clean(params)
    period = Period.parse(params)
    c = socket.assigns.category

    rows =
      Cache.fetch({:category, c.id, period.from, period.to}, Cache.ttl_for(period.to), fn ->
        Reports.category_channels(c.id, period.from, period.to)
      end)

    {:noreply,
     assign(socket, period: period, rows: rows, params: Map.take(params, ~w(period from to)))}
  end

  @impl true
  def handle_event("custom_range", form, socket) do
    case PageParams.custom_range(form["from"], form["to"]) do
      {:ok, range} ->
        params = socket.assigns.params |> Map.delete("period") |> Map.merge(range)

        {:noreply,
         push_patch(socket,
           to: ~p"/category/#{socket.assigns.category.slug}?#{params}"
         )}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="category" phx-hook="Format">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="text-2xl font-semibold tracking-tight">{@category.name}</h1>
          <span class="flex-1"></span>
          <.period_picker period={@period} path={~p"/category/#{@category.slug}"} params={@params} />
        </div>
        <div class="mt-4 overflow-x-auto">
          <table id="category-channels" class="table table-sm">
            <thead>
              <tr>
                <th>#</th>
                <th>{gettext("Channel")}</th>
                <th class="text-end">{gettext("Hours watched")}</th>
                <th class="text-end">{gettext("Airtime")}</th>
                <th class="text-end">{gettext("Avg viewers")}</th>
                <th class="text-end">{gettext("Peak")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{r, i} <- Enum.with_index(@rows, 1)}>
                <td class="opacity-60">{i}</td>
                <td>
                  <.link
                    navigate={~p"/c/#{r.slug}/categories?#{Period.to_params(@period)}"}
                    class="link font-medium"
                  >{r.slug}</.link>
                </td>
                <td class="text-end"><.num value={r.hours_watched} compact /></td>
                <td class="text-end"><.duration seconds={r.airtime_s} /></td>
                <td class="text-end"><.num value={r.avg_viewers} /></td>
                <td class="text-end"><.num value={r.peak_viewers} /></td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@rows == []} class="mt-4 text-sm opacity-60">
          {gettext("No tracked channel streamed this in the period.")}
        </p>
      </div>
    </Layouts.app>
    """
  end
end
