defmodule KickTrackerWeb.CompareLive do
  @moduledoc """
  Compare (project.md §13.2): 2–4 channels on the same metrics and
  period, overlaid, with the chatters they share. `/compare?c=a,b,c`.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Cache, Groups, Reports}
  alias KickTrackerWeb.Period

  @metrics ~w(viewers chat followers)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Compare"),
       all: Reports.channels(),
       groups: Groups.list(public: true)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    slugs = (params["c"] || "") |> String.split(",", trim: true) |> Enum.take(4)

    channels =
      slugs
      |> Enum.map(&Reports.channel_by_slug/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    period = Period.parse(params)
    metric = if params["metric"] in @metrics, do: params["metric"], else: "viewers"

    rows =
      for c <- channels do
        Cache.fetch({:period, c.id, period.from, period.to}, Cache.ttl_for(period.to), fn ->
          Reports.period(c, period.from, period.to)
        end)
        |> Map.put(:slug, c.slug)
      end

    overlap =
      if length(channels) >= 2,
        do: Reports.overlap(Enum.map(channels, & &1.id), period.from, period.to)

    ids = Enum.map(channels, & &1.id)
    by_id = Map.new(socket.assigns.all, &{&1.id, &1.slug})

    group_links =
      for g <- socket.assigns.groups,
          slugs = g.channel_ids |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1) |> Enum.take(4),
          length(slugs) >= 2,
          do: {g.name, Enum.join(slugs, ",")}

    {:noreply,
     assign(socket,
       addable: Enum.reject(socket.assigns.all, &(&1.id in ids)),
       group_links: group_links,
       channels: channels,
       period: period,
       metric: metric,
       rows: rows,
       overlap: overlap,
       params: Map.take(params, ~w(c metric period from to))
     )}
  end

  @impl true
  def handle_event("add", %{"slug" => slug}, socket) do
    slugs = Enum.map(socket.assigns.channels, & &1.slug)
    slugs = if slug in slugs or slug == "", do: slugs, else: Enum.take(slugs ++ [slug], 4)

    {:noreply,
     push_patch(socket,
       to: compare_path(Map.put(socket.assigns.params, "c", Enum.join(slugs, ",")))
     )}
  end

  def handle_event("remove", %{"slug" => slug}, socket) do
    slugs = socket.assigns.channels |> Enum.map(& &1.slug) |> List.delete(slug)

    {:noreply,
     push_patch(socket,
       to: compare_path(Map.put(socket.assigns.params, "c", Enum.join(slugs, ",")))
     )}
  end

  defp compare_path(params), do: "/compare?" <> URI.encode_query(params)

  defp metric_label("viewers"), do: gettext("Viewers")
  defp metric_label("chat"), do: gettext("Chat messages")
  defp metric_label("followers"), do: gettext("Followers")

  defp shared(%{pairs: pairs}, a, b), do: Map.get(pairs, {min(a, b), max(a, b)}, 0)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:compare}>
      <div id="compare" phx-hook="Format">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="text-2xl font-semibold tracking-tight">{gettext("Compare")}</h1>
          <span class="flex-1"></span>
          <.period_picker period={@period} path="/compare" params={@params} />
        </div>

        <div class="mt-3 flex flex-wrap items-center gap-2">
          <span :for={c <- @channels} class="badge badge-lg gap-1">
            {c.slug}
            <button
              type="button"
              phx-click="remove"
              phx-value-slug={c.slug}
              aria-label={gettext("Remove %{c}", c: c.slug)}
            >×</button>
          </span>
          <form :if={length(@channels) < 4} id="add-channel" phx-submit="add" class="flex gap-1">
            <select name="slug" class="select select-sm w-48" aria-label={gettext("Add a channel")}>
              <option value="">{gettext("Add a channel…")}</option>
              <option :for={c <- @addable} value={c.slug}>{c.slug}</option>
            </select>
            <button class="btn btn-sm">{gettext("Add")}</button>
          </form>
          <span :for={{name, slugs} <- @group_links} class="text-sm">
            <.link patch={compare_path(Map.put(@params, "c", slugs))} class="link">{name}</.link>
          </span>
        </div>

        <%= if length(@channels) < 2 do %>
          <p class="mt-6 text-sm opacity-70">
            {gettext("Pick two to four channels to compare them.")}
          </p>
        <% else %>
          <div class="mt-4 flex gap-2 text-sm">
            <.link
              :for={m <- ~w(viewers chat followers)}
              patch={compare_path(Map.put(@params, "metric", m))}
              class={[
                "rounded px-2 py-1",
                @metric == m && "bg-base-300 font-medium",
                @metric != m && "opacity-70"
              ]}
            >
              {metric_label(m)}
            </.link>
          </div>
          <div class="mt-2">
            <.chart
              id={"compare-chart-#{@metric}"}
              kind="timeseries"
              title={metric_label(@metric)}
              src={"/data/v1/compare?" <> URI.encode_query(Map.merge(Period.to_params(@period), %{"c" => Enum.map_join(@channels, ",", & &1.slug), "metric" => @metric}))}
              class="h-80"
            />
          </div>

          <div class="mt-4 overflow-x-auto">
            <table id="compare-table" class="table table-sm">
              <thead>
                <tr>
                  <th></th>
                  <th :for={r <- @rows} class="text-end">{r.slug}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={
                  {label, key} <- [
                    {gettext("Hours watched"), :hours_watched},
                    {gettext("Average viewers"), :avg_viewers},
                    {gettext("Peak viewers"), :peak_viewers},
                    {gettext("Streams"), :streams},
                    {gettext("Follower gain"), :follower_gain},
                    {gettext("Unique chatters"), :unique_chatters},
                    {gettext("Messages"), :messages},
                    {gettext("Kicks"), :kicks}
                  ]
                }>
                  <td>{label}</td>
                  <td :for={r <- @rows} class="text-end"><.num value={Map.get(r, key)} /></td>
                </tr>
                <tr>
                  <td>{gettext("Airtime")}</td>
                  <td :for={r <- @rows} class="text-end"><.duration seconds={r.airtime_s} /></td>
                </tr>
              </tbody>
            </table>
          </div>

          <section :if={@overlap} class="mt-6">
            <h2 class="font-medium">{gettext("Shared chatters")}</h2>
            <p class="text-xs opacity-60">
              {gettext("People who chatted in both channels during the period.")}
            </p>
            <table id="overlap" class="table table-sm mt-2 w-auto">
              <thead>
                <tr>
                  <th></th><th :for={b <- @channels} class="text-end">{b.slug}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={a <- @channels}>
                  <th>{a.slug}</th>
                  <td :for={b <- @channels} class="text-end">
                    <%= if a.id == b.id do %>
                      <span class="opacity-60"><.num value={Map.get(@overlap.counts, a.id, 0)} /></span>
                    <% else %>
                      <.num value={shared(@overlap, a.id, b.id)} />
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
