defmodule KickTrackerWeb.HomeLive do
  @moduledoc """
  The home page (project.md §13.2): who is live now, leaderboards over a
  period (optionally one public group), and notable moments. "Now" comes
  from the collector's one aggregated `"live"` broadcast per poll (§13.5).
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Cache, Groups, Reports, Settings}
  alias KickTrackerWeb.{PageParams, Period}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(KickTracker.PubSub, KickTracker.Tracking.live_topic())

    {:ok,
     socket
     |> assign(
       page_title: gettext("Live now"),
       page_description:
         gettext("Who is live now, leaderboards and notable moments of the channels we track.")
     )
     |> assign(live: Reports.live_now(), seen: nil, spark_at: minute(DateTime.utc_now()))}
  end

  # The sparklines' data URL changes each minute, so their hook fetches
  # the moved window (cacheable JSON, never kept here: §13.5).
  defp minute(%DateTime{} = at), do: div(DateTime.to_unix(at), 60) * 60

  @impl true
  def handle_params(params, _uri, socket) do
    params = PageParams.clean(params)
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

    # Gifters are people: named only where the site shows top people.
    notable =
      if Settings.get("top_people_public"),
        do: notable,
        else: Enum.map(notable, &Map.delete(&1, :who))

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
  def handle_event("custom_range", form, socket) do
    case PageParams.custom_range(form["from"], form["to"]) do
      {:ok, range} ->
        params = socket.assigns.params |> Map.delete("period") |> Map.merge(range)
        {:noreply, push_patch(socket, to: home_path(params))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # The broadcast names every channel Kick reports live, private ones and
  # ones without an open stream here included. Only a change among the
  # public ones reads the list again, once (not every minute while, say, a
  # private channel is live); otherwise the viewers are updated in place.
  @impl true
  def handle_info({:live, %{viewers: viewers} = msg}, socket) do
    public = public_ids()
    relevant = viewers |> Map.keys() |> Enum.filter(&MapSet.member?(public, &1)) |> MapSet.new()
    current = MapSet.new(socket.assigns.live, & &1.channel_id)

    live =
      if MapSet.equal?(relevant, socket.assigns.seen || current),
        do: socket.assigns.live,
        else: Cache.fetch({:live_now, Enum.sort(relevant)}, 30, &Reports.live_now/0)

    live =
      live
      |> Enum.map(&%{&1 | viewers: Map.get(viewers, &1.channel_id, &1.viewers)})
      |> Enum.sort_by(&(-(&1.viewers || 0)))

    {:noreply,
     assign(socket,
       live: live,
       seen: relevant,
       spark_at: minute(Map.get(msg, :at) || DateTime.utc_now())
     )}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp public_ids do
    Cache.fetch({:public_channel_ids}, 60, fn -> MapSet.new(Reports.channels(), & &1.id) end)
  end

  defp metric_label("hours_watched"), do: gettext("Hours watched")
  defp metric_label("avg_viewers"), do: gettext("Average viewers")
  defp metric_label("peak_viewers"), do: gettext("Peak viewers")
  defp metric_label("follower_gain"), do: gettext("Follower gain")
  defp metric_label("kicks"), do: gettext("Kicks")

  defp home_path(params), do: "/?" <> URI.encode_query(params)

  defp metric_value(row, metric), do: to_float(Map.get(row, String.to_existing_atom(metric)))

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n * 1.0
  defp to_float(_), do: 0.0

  defp share(value, max) when max > 0, do: Float.round(max(value, 0) / max * 100, 1)
  defp share(_, _), do: 0

  defp live_for(%DateTime{} = at), do: format_duration(DateTime.diff(DateTime.utc_now(), at))
  defp live_for(_), do: nil

  # Unknown if any live channel has no current reading: counting it as 0
  # would show a confident undercount during a polling gap.
  @doc false
  def total_watching(live), do: live |> Enum.map(& &1.viewers) |> known_sum()

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :board_max,
        assigns.board |> Enum.map(&metric_value(&1, assigns.metric)) |> Enum.max(fn -> 0.0 end)
      )

    ~H"""
    <Layouts.app flash={@flash} active={:live}>
      <div id="home" phx-hook="Format">
        <section>
          <div class="flex flex-wrap items-end gap-x-6 gap-y-2">
            <h1 class="text-2xl font-semibold tracking-tight sm:text-3xl">{gettext("Live now")}</h1>
            <div :if={@live != []} class="flex items-center gap-4 pb-1 text-sm text-base-content/70">
              <span>
                <span class="font-semibold text-base-content tabular-nums">{length(@live)}</span>
                {ngettext("channel live", "channels live", length(@live))}
              </span>
              <span>
                <.num value={total_watching(@live)} compact class="font-semibold text-base-content" />
                {gettext("watching")}
              </span>
            </div>
          </div>
          <div
            :if={@live == []}
            class="card-surface mt-4 flex items-center gap-3 p-6 text-sm text-base-content/70"
          >
            <.icon name="hero-moon" class="size-5 opacity-60" />
            {gettext("Nobody we track is live right now.")}
          </div>
          <ul id="live-now" class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <li :for={l <- @live} id={"live-#{l.channel_id}"} class="min-w-0">
              <.link
                navigate={~p"/c/#{l.slug}/streams/#{l.stream_id}"}
                class="card-surface block p-4"
              >
                <div class="flex items-center gap-3">
                  <.avatar name={l.slug} channel_id={l.channel_id} />
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="truncate font-semibold">{l.slug}</span>
                      <.live_badge />
                    </div>
                    <div class="mt-0.5 text-xs text-base-content/60">
                      {gettext("live for %{duration}", duration: live_for(l.started_at))}
                    </div>
                  </div>
                  <div class="text-end">
                    <div class="m-hw text-metric text-xl font-bold leading-tight tracking-tight tabular-nums">
                      <.num value={l.viewers} />
                    </div>
                    <div class="text-[0.7rem] text-base-content/60">{gettext("viewers")}</div>
                  </div>
                </div>
                <div class="mt-3 flex min-w-0 items-center gap-2 text-xs">
                  <span
                    :if={l.category}
                    class="badge badge-sm shrink-0 border-base-300 bg-base-200"
                  >{l.category}</span>
                  <span class="truncate text-base-content/70" title={l.title}>{l.title}</span>
                </div>
                <div
                  id={"spark-#{l.channel_id}"}
                  phx-hook="Chart"
                  phx-update="ignore"
                  data-kind="sparkline"
                  data-src={~p"/data/v1/sparklines/#{l.slug}?at=#{@spark_at}"}
                  data-error={gettext("Couldn't load this chart.")}
                  class="inset-well relative mt-3 h-14"
                >
                </div>
                <div class="mt-1 flex justify-between text-[0.65rem] text-base-content/70">
                  <span>{gettext("3 h ago")}</span><span>{gettext("now")}</span>
                </div>
              </.link>
            </li>
          </ul>
        </section>

        <section class="mt-12">
          <div class="flex flex-wrap items-center gap-3">
            <.icon_tile metric={board_metric(@metric)} />
            <h2 class="text-xl font-semibold tracking-tight">{gettext("Leaderboard")}</h2>
            <span class="flex-1"></span>
            <.period_picker period={@period} path="/" params={@params} />
          </div>
          <div class="mt-3 flex flex-wrap items-center gap-2">
            <nav class="segmented" aria-label={gettext("Rank by")}>
              <.link
                :for={m <- Reports.leaderboard_metrics()}
                patch={home_path(Map.put(@params, "metric", m))}
                class={["segmented-item", @metric == m && "is-active"]}
                aria-current={@metric == m && "true"}
              >
                {metric_label(m)}
              </.link>
            </nav>
            <nav :if={@groups != []} class="segmented" aria-label={gettext("Group")}>
              <.link
                patch={home_path(Map.delete(@params, "group"))}
                class={["segmented-item", is_nil(@group) && "is-active"]}
              >
                {gettext("All channels")}
              </.link>
              <.link
                :for={g <- @groups}
                patch={home_path(Map.put(@params, "group", g.slug))}
                class={["segmented-item", @group && @group.id == g.id && "is-active"]}
              >
                {g.name}
              </.link>
            </nav>
          </div>
          <div class="card-surface mt-3 overflow-x-auto">
            <table id="leaderboard" class="table">
              <thead>
                <tr class="text-xs text-base-content/60">
                  <th class="w-10">#</th>
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
                <tr :if={@board == []}>
                  <td colspan="7" class="py-8 text-center text-sm text-base-content/60">
                    {gettext("Nothing recorded in this period.")}
                  </td>
                </tr>
                <tr :for={{r, i} <- Enum.with_index(@board, 1)} class="hover:bg-base-200/60">
                  <td class="tabular-nums text-base-content/70">{i}</td>
                  <td class="min-w-44">
                    <.link
                      navigate={~p"/c/#{r.slug}?#{Period.to_params(@period)}"}
                      class="flex items-center gap-2.5 font-medium hover:underline"
                    >
                      <.avatar name={r.slug} channel_id={r.channel_id} class="size-7 text-xs" />
                      <span class="truncate">{r.slug}</span>
                    </.link>
                    <div class={["meter ms-9.5 mt-1.5 max-w-48", "m-#{board_metric(@metric)}"]}>
                      <span style={"width: #{share(metric_value(r, @metric), @board_max)}%"}></span>
                    </div>
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

        <section :if={@notable != []} class="mt-12">
          <h2 class="flex items-center gap-3 text-xl font-semibold tracking-tight">
            <.icon_tile icon="hero-sparkles" />{gettext("Notable moments")}
          </h2>
          <ul id="notable" class="mt-4 grid gap-3 sm:grid-cols-2">
            <li :for={n <- @notable} class="card-surface flex gap-3 p-4 text-sm">
              <span class={[
                "icon-tile",
                n.kind == "record" && "m-peak",
                n.kind == "gifts" && "m-subs",
                n.kind not in ["record", "gifts"] && "m-hw"
              ]}>
                <.icon :if={n.kind == "record"} name="hero-trophy-micro" class="size-4" />
                <.icon :if={n.kind == "gifts"} name="hero-gift-micro" class="size-4" />
                <.icon
                  :if={n.kind not in ["record", "gifts"]}
                  name="hero-sparkles-micro"
                  class="size-4"
                />
              </span>
              <div class="min-w-0">
                <div>
                  <%= case n.kind do %>
                    <% "record" -> %>
                      {gettext("New peak record for")} <.link
                        navigate={~p"/c/#{n.slug}/streams/#{n.stream_id}"}
                        class="font-medium hover:underline"
                      >{n.slug}</.link>:
                      <.num value={n.value} class="font-semibold" /> {gettext("viewers")}
                    <% "gifts" -> %>
                      <.num value={n.value} class="font-semibold" /> {gettext(
                        "subs gifted at once on"
                      )}
                      <.link
                        navigate={
                          if n.stream_id,
                            do: ~p"/c/#{n.slug}/streams/#{n.stream_id}",
                            else: ~p"/c/#{n.slug}"
                        }
                        class="font-medium hover:underline"
                      >{n.slug}</.link>
                      <span :if={n[:who]} class="text-base-content/70">
                        {gettext("by %{who}", who: n.who)}
                      </span>
                    <% kind -> %>
                      {event_label(kind)} ·
                      <.link navigate={~p"/c/#{n.slug}"} class="hover:underline">{n.slug}</.link>
                      {n[:other]}
                      <.num value={n.value} />
                  <% end %>
                </div>
                <div class="mt-0.5 text-xs text-base-content/70"><.time at={n.at} /></div>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The hue of the metric a leaderboard ranks by.
  defp board_metric("hours_watched"), do: :hw
  defp board_metric("avg_viewers"), do: :avg
  defp board_metric("peak_viewers"), do: :peak
  defp board_metric("follower_gain"), do: :followers
  defp board_metric("kicks"), do: :subs
end
