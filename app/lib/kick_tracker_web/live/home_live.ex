defmodule KickTrackerWeb.HomeLive do
  @moduledoc """
  The home page (project.md §13.2): who is live now, leaderboards over a
  period (optionally one public group), and notable moments. "Now" comes
  from the collector's one aggregated `"live"` broadcast per poll (§13.5).
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Cache, Groups, Reports}
  alias KickTracker.Tracking.Poller
  alias KickTrackerWeb.Period

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(KickTracker.PubSub, Poller.live_topic())
    {:ok, socket |> assign(page_title: gettext("Live now")) |> load_live()}
  end

  defp load_live(socket) do
    live = Reports.live_now()
    assign(socket, live: live, sparks: Reports.sparklines(Enum.map(live, & &1.channel_id)))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = Period.parse(params, default: "30d")

    metric =
      if params["metric"] in Reports.leaderboard_metrics(),
        do: params["metric"],
        else: "hours_watched"

    groups = Groups.list(public: true)
    group = Enum.find(groups, &(&1.slug == params["group"]))
    ids = group && group.channel_ids

    board =
      Cache.fetch(
        {:leaderboard, period.from, period.to, metric, ids},
        Cache.ttl_for(period.to),
        fn ->
          Reports.leaderboard(period.from, period.to, metric, ids)
        end
      )

    notable =
      Cache.fetch({:notable, period.from, period.to}, Cache.ttl_for(period.to), fn ->
        Reports.notable(period.from, period.to)
      end)

    {:noreply,
     assign(socket,
       period: period,
       metric: metric,
       groups: groups,
       group: group,
       params: Map.take(params, ~w(metric group period from to)),
       board: board,
       notable: notable
     )}
  end

  @impl true
  def handle_info({:live, %{viewers: viewers}}, socket) do
    current = MapSet.new(socket.assigns.live, & &1.channel_id)

    if MapSet.equal?(current, MapSet.new(Map.keys(viewers))) do
      live =
        Enum.map(
          socket.assigns.live,
          &%{&1 | viewers: Map.get(viewers, &1.channel_id, &1.viewers)}
        )

      {:noreply, assign(socket, live: Enum.sort_by(live, &(-(&1.viewers || 0))))}
    else
      # Someone went live or offline: read the list again.
      {:noreply, load_live(socket)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp metric_label("hours_watched"), do: gettext("Hours watched")
  defp metric_label("avg_viewers"), do: gettext("Average viewers")
  defp metric_label("peak_viewers"), do: gettext("Peak viewers")
  defp metric_label("follower_gain"), do: gettext("Follower gain")
  defp metric_label("kicks"), do: gettext("Kicks")

  defp home_path(params), do: "/?" <> URI.encode_query(params)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="home" phx-hook="Format">
        <section>
          <h1 class="text-2xl font-semibold tracking-tight">{gettext("Live now")}</h1>
          <p :if={@live == []} class="mt-2 text-sm opacity-70">
            {gettext("Nobody we track is live right now.")}
          </p>
          <ul id="live-now" class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <li
              :for={l <- @live}
              id={"live-#{l.channel_id}"}
              class="rounded-box border border-base-300 p-3 transition hover:border-base-content/30"
            >
              <.link navigate={~p"/c/#{l.slug}/streams/#{l.stream_id}"} class="block">
                <div class="flex items-center gap-2">
                  <span class="font-medium">{l.slug}</span>
                  <.live_badge />
                  <span class="flex-1"></span>
                  <span class="text-lg font-semibold"><.num value={l.viewers} /></span>
                </div>
                <div class="mt-1 truncate text-xs opacity-70">{l.category} · {l.title}</div>
                <div
                  id={"spark-#{l.channel_id}"}
                  phx-hook="Chart"
                  phx-update="ignore"
                  data-kind="sparkline"
                  data-values={Jason.encode!(@sparks[l.channel_id] || [])}
                  class="mt-2 h-10"
                >
                </div>
              </.link>
            </li>
          </ul>
        </section>

        <section class="mt-10">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-xl font-semibold tracking-tight">{gettext("Leaderboard")}</h2>
            <span class="flex-1"></span>
            <.period_picker period={@period} path="/" params={@params} />
          </div>
          <div class="mt-2 flex flex-wrap gap-2 text-sm">
            <.link
              :for={m <- Reports.leaderboard_metrics()}
              patch={home_path(Map.put(@params, "metric", m))}
              class={[
                "rounded px-2 py-1",
                @metric == m && "bg-base-300 font-medium",
                @metric != m && "opacity-70 hover:opacity-100"
              ]}
            >
              {metric_label(m)}
            </.link>
            <span :if={@groups != []} class="mx-2 opacity-30">|</span>
            <.link
              :if={@groups != []}
              patch={home_path(Map.delete(@params, "group"))}
              class={["rounded px-2 py-1", is_nil(@group) && "bg-base-300"]}
            >
              {gettext("All channels")}
            </.link>
            <.link
              :for={g <- @groups}
              patch={home_path(Map.put(@params, "group", g.slug))}
              class={["rounded px-2 py-1", @group && @group.id == g.id && "bg-base-300"]}
            >
              {g.name}
            </.link>
          </div>
          <div class="mt-3 overflow-x-auto">
            <table id="leaderboard" class="table table-sm">
              <thead>
                <tr>
                  <th>#</th>
                  <th>{gettext("Channel")}</th>
                  <th class="text-end">{gettext("Hours watched")}</th>
                  <th class="text-end">{gettext("Avg viewers")}</th>
                  <th class="text-end">{gettext("Peak")}</th>
                  <th :if={@metric == "follower_gain"} class="text-end">
                    {gettext("Follower gain")}
                  </th>
                  <th class="text-end">{gettext("Kicks")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{r, i} <- Enum.with_index(@board, 1)}>
                  <td class="opacity-60">{i}</td>
                  <td>
                    <.link
                      navigate={~p"/c/#{r.slug}?#{Period.to_params(@period)}"}
                      class="link font-medium"
                    >{r.slug}</.link>
                  </td>
                  <td class={["text-end", @metric == "hours_watched" && "font-semibold"]}>
                    <.num value={r.hours_watched} compact />
                  </td>
                  <td class={["text-end", @metric == "avg_viewers" && "font-semibold"]}>
                    <.num value={r.avg_viewers} />
                  </td>
                  <td class={["text-end", @metric == "peak_viewers" && "font-semibold"]}>
                    <.num value={r.peak_viewers} />
                  </td>
                  <td :if={@metric == "follower_gain"} class="text-end font-semibold">
                    <.num value={r.follower_gain} />
                  </td>
                  <td class={["text-end", @metric == "kicks" && "font-semibold"]}>
                    <.num value={r.kicks} compact />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section :if={@notable != []} class="mt-10">
          <h2 class="text-xl font-semibold tracking-tight">{gettext("Notable moments")}</h2>
          <ul id="notable" class="mt-3 grid gap-2 sm:grid-cols-2">
            <li :for={n <- @notable} class="rounded-box border border-base-300 p-3 text-sm">
              <span class="text-xs opacity-60"><.time at={n.at} /></span>
              <div>
                <%= case n.kind do %>
                  <% "record" -> %>
                    {gettext("New peak record for")} <.link
                      navigate={~p"/c/#{n.slug}/streams/#{n.stream_id}"}
                      class="link font-medium"
                    >{n.slug}</.link>:
                    <.num value={n.value} class="font-semibold" /> {gettext("viewers")}
                  <% "gifts" -> %>
                    <.num value={n.value} class="font-semibold" /> {gettext("subs gifted at once on")}
                    <.link
                      navigate={
                        if n.stream_id,
                          do: ~p"/c/#{n.slug}/streams/#{n.stream_id}",
                          else: ~p"/c/#{n.slug}"
                      }
                      class="link font-medium"
                    >{n.slug}</.link>
                    <span :if={n[:who]} class="opacity-70">{gettext("by %{who}", who: n.who)}</span>
                  <% kind -> %>
                    {kind} ·
                    <.link navigate={~p"/c/#{n.slug}"} class="link">{n.slug}</.link> {n[:other]}
                    <.num value={n.value} />
                <% end %>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
