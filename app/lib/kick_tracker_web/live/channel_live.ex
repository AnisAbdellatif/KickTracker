defmodule KickTrackerWeb.ChannelLive do
  @moduledoc """
  A channel's pages (project.md §13.2): overview, streams, chat, support
  and categories, one LiveView with a live action each. Everything shown
  is reproducible from the URL (period and options in the query).

  History comes from `/data/v1` (cacheable JSON fetched by the chart hook);
  only "now" (the live badge, current viewers) comes over LiveView, from
  the channel's PubSub topic.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Cache, Reports, Series, Settings}
  alias KickTracker.Tracking.ChannelServer
  alias KickTrackerWeb.{PageParams, Period}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Reports.channel_by_slug(slug) do
      nil ->
        raise KickTrackerWeb.NotFoundError, "no channel #{slug}"

      channel ->
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(KickTracker.PubSub, ChannelServer.topic(channel.id))

        {:ok, socket |> assign(channel: channel) |> assign_live()}
    end
  end

  defp assign_live(socket) do
    live = Enum.find(Reports.live_now(), &(&1.channel_id == socket.assigns.channel.id))
    assign(socket, live: live)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = PageParams.clean(params)
    channel = socket.assigns.channel
    # A renamed channel's old slug lands on the current one.
    if params["slug"] != channel.slug do
      {:noreply,
       push_patch(socket,
         to: page_path(channel, socket.assigns.live_action, Map.delete(params, "slug"))
       )}
    else
      period = Period.parse(params, since: channel.tracked_since)
      params = Map.delete(params, "slug")

      socket =
        socket
        |> assign(period: period, params: params, query: data_query(period, params))
        |> assign(refresh: Period.refresh(period))
        |> assign(page_title: title(channel, socket.assigns.live_action))
        |> assign(
          page_description:
            gettext("Viewers, streams, chat and support of %{channel}, tracked over time.",
              channel: channel.slug
            )
        )
        |> load(socket.assigns.live_action)

      {:noreply, socket}
    end
  end

  defp data_query(period, _params), do: URI.encode_query(Period.to_params(period))

  defp title(channel, :overview), do: channel.slug
  defp title(channel, action), do: "#{channel.slug} · #{tab_label(action)}"

  defp load(socket, :overview) do
    %{channel: c, period: p} = socket.assigns

    kpis =
      Cache.fetch({:kpis, c.id, p.from, p.to}, Cache.ttl_for(p.to), fn ->
        Reports.kpis(c, p.from, p.to)
      end)

    assign(socket,
      kpis: kpis,
      coverage: Series.coverage(c, "api", p.from, p.to),
      stream_rows: Reports.streams(c, limit: 8),
      records: Reports.records(c),
      weekdays:
        Cache.fetch({:weekdays, c.id, p.from, p.to}, Cache.ttl_for(p.to), fn ->
          Reports.weekdays(c, p.from, p.to)
        end)
    )
  end

  defp load(socket, :streams) do
    %{channel: c, period: p, params: params} = socket.assigns
    category_id = parse_int(params["category"])

    streams =
      Reports.streams(c, from: p.from, to: p.to, category_id: category_id)
      |> sort(params["sort"], params["dir"])

    categories =
      Reports.streams(c, from: p.from, to: p.to)
      |> Enum.map(&{&1.category_id, &1.category})
      |> Enum.uniq()
      |> Enum.reject(&is_nil(elem(&1, 0)))

    assign(socket, stream_rows: streams, categories: categories, category_id: category_id)
  end

  defp load(socket, :chat) do
    %{channel: c, period: p} = socket.assigns

    assign(socket,
      retention:
        Cache.fetch({:retention, c.id, p.from, p.to}, Cache.ttl_for(p.to), fn ->
          Reports.chatter_retention(c, p.from, p.to)
        end),
      kpis: Reports.kpis(c, p.from, p.to),
      coverage: Series.coverage(c, "chat", p.from, p.to)
    )
  end

  defp load(socket, :support) do
    %{channel: c, period: p} = socket.assigns

    if Settings.get("support_page_public") do
      assign(socket,
        support: Reports.support_summary(c, p.from, p.to),
        ingress: Series.coverage(c, "ingress", p.from, p.to),
        stream_rows: Reports.streams(c, from: p.from, to: p.to, limit: 50)
      )
    else
      raise KickTrackerWeb.NotFoundError, "support page not public"
    end
  end

  defp load(socket, :categories) do
    %{channel: c, period: p} = socket.assigns
    assign(socket, categories: Reports.categories(c, p.from, p.to))
  end

  @sortable ~w(started_at airtime_s avg_viewers peak_viewers hours_watched follower_gain unique_chatters messages)

  defp sort(streams, key, dir) when key in @sortable do
    k = String.to_existing_atom(key)
    {known, unknown} = Enum.split_with(streams, &(Map.get(&1, k) != nil))

    known =
      Enum.sort_by(known, &sortable(Map.get(&1, k)), if(dir == "asc", do: :asc, else: :desc))

    # Unknown values last, whichever the direction.
    known ++ unknown
  end

  defp sort(streams, _key, _dir), do: streams

  defp sortable(%DateTime{} = d), do: DateTime.to_unix(d)
  defp sortable(v), do: v

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  ## Live

  @impl true
  def handle_info({:viewers, %{viewers: v, at: at}}, socket) do
    live = socket.assigns.live && %{socket.assigns.live | viewers: v, observed_at: at}
    {:noreply, if(live, do: assign(socket, live: live), else: assign_live(socket))}
  end

  def handle_info({event, _, _}, socket) when event in [:stream_ended],
    do: {:noreply, assign_live(socket)}

  def handle_info({:stream_started, _}, socket), do: {:noreply, assign_live(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  ## Paths

  defp page_path(channel, action, params) do
    base =
      case action do
        :overview -> ~p"/c/#{channel.slug}"
        :streams -> ~p"/c/#{channel.slug}/streams"
        :chat -> ~p"/c/#{channel.slug}/chat"
        :support -> ~p"/c/#{channel.slug}/support"
        :categories -> ~p"/c/#{channel.slug}/categories"
      end

    if params == %{}, do: base, else: base <> "?" <> URI.encode_query(params)
  end

  # Webhook counts are unknown, not 0, when nothing was being received.
  defp known(_value, coverage) when coverage == 0, do: nil
  defp known(value, _coverage), do: value

  defp tab_label(:overview), do: gettext("Overview")
  defp tab_label(:streams), do: gettext("Streams")
  defp tab_label(:chat), do: gettext("Chat")
  defp tab_label(:support), do: gettext("Support")
  defp tab_label(:categories), do: gettext("Categories")

  defp tabs do
    if Settings.get("support_page_public"),
      do: [:overview, :streams, :chat, :support, :categories],
      else: [:overview, :streams, :chat, :categories]
  end

  defp sort_link(assigns) do
    ~H"""
    <.link
      patch={
        page_path(
          @channel,
          :streams,
          Map.merge(@params, %{
            "sort" => @key,
            "dir" => if(@params["sort"] == @key and @params["dir"] != "asc", do: "asc", else: "desc")
          })
        )
      }
      class="link link-hover"
    >
      {@label}<span :if={@params["sort"] == @key}>{if @params["dir"] == "asc", do: " ▲", else: " ▼"}</span>
    </.link>
    """
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="channel-page" phx-hook="Format">
        <header class="flex flex-wrap items-center gap-x-4 gap-y-3">
          <.avatar
            name={@channel.slug}
            channel_id={@channel.id}
            class="size-12 text-xl sm:size-14 sm:text-2xl"
          />
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <h1 class="truncate text-2xl font-semibold tracking-tight sm:text-3xl">
                {@channel.slug}
              </h1>
              <.live_badge :if={@live} />
              <span :if={!@channel.active} class="badge badge-ghost badge-sm">{gettext(
                "not tracked at the moment"
              )}</span>
            </div>
            <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-base-content/60">
              <span :if={@live && @live.viewers}>
                <.num value={@live.viewers} class="font-semibold text-base-content" />
                {gettext("watching")}
              </span>
              <.link
                :if={@live}
                navigate={~p"/c/#{@channel.slug}/streams/#{@live.stream_id}"}
                class="inline-flex items-center gap-0.5 font-medium text-primary hover:underline"
              >
                {gettext("Current stream")}<.icon
                  name="hero-arrow-right-micro"
                  class="size-4 rtl:rotate-180"
                />
              </.link>
              <span>
                {gettext("Tracked since")} <.time at={@channel.tracked_since} fmt="date" />
              </span>
            </div>
          </div>
          <button
            id="tz-switch"
            phx-hook="TzSwitch"
            phx-update="ignore"
            type="button"
            class="btn btn-ghost btn-sm aria-pressed:btn-active"
            aria-pressed="false"
            aria-label={gettext("Channel time")}
            title={gettext("Show times in the channel's timezone (%{tz})", tz: @channel.timezone)}
          >
            <.icon name="hero-globe-alt-micro" class="size-4" />
            <span class="hidden sm:inline">{gettext("Channel time")}</span>
          </button>
        </header>

        <div class="mt-6 flex flex-wrap items-end gap-x-4 gap-y-3">
          <.tabs
            class="w-full min-w-0 sm:w-auto sm:flex-1"
            active={@live_action}
            tabs={
              for tab <- tabs(),
                  do: {tab, tab_label(tab), page_path(@channel, tab, Period.to_params(@period))}
            }
          />
          <div class="pb-1.5">
            <.period_picker
              period={@period}
              path={page_path(@channel, @live_action, %{})}
              params={@params}
              tz={@channel.timezone}
            />
          </div>
        </div>

        <div class="mt-5">
          {render_tab(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_tab(%{live_action: :overview} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-xs opacity-80">
      <.coverage_badge fraction={@coverage} />
      <span>{gettext("Days and weekdays in %{tz} time.", tz: @channel.timezone)}</span>
    </div>
    <section id="kpis" class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
      <.kpi
        label={gettext("Hours watched")}
        metric={:hw}
        value={@kpis.now.hours_watched}
        previous={@kpis.before.hours_watched}
        hint={gettext("Σ viewers × time between readings, capped at 75s")}
      />
      <.kpi
        label={gettext("Average viewers")}
        metric={:avg}
        value={@kpis.now.avg_viewers}
        previous={@kpis.before.avg_viewers}
      />
      <.kpi
        label={gettext("Peak viewers")}
        metric={:peak}
        value={@kpis.now.peak_viewers}
        previous={@kpis.before.peak_viewers}
      />
      <.kpi
        label={gettext("Airtime")}
        metric={:airtime}
        value={@kpis.now.airtime_s}
        previous={@kpis.before.airtime_s}
        kind={:duration}
      />
      <.kpi
        label={gettext("Follower gain")}
        metric={:followers}
        value={@kpis.now.follower_gain}
        previous={@kpis.before.follower_gain}
        note={
          @kpis.now.follower_gain_since &&
            gettext("since the first reading, %{date}",
              date: Calendar.strftime(@kpis.now.follower_gain_since, "%Y-%m-%d")
            )
        }
      />
      <.kpi
        label={gettext("Unique chatters")}
        metric={:chat}
        value={@kpis.now.unique_chatters}
        previous={@kpis.before.unique_chatters}
      />
    </section>

    <div class="mt-4 grid gap-4 lg:grid-cols-3">
      <div class="lg:col-span-2">
        <.chart
          id="viewers-chart"
          refresh={@refresh}
          kind="timeseries"
          title={gettext("Viewers")}
          metric={:avg}
          src={"/data/v1/channels/#{@channel.slug}/viewers?#{@query}"}
          opts={
            %{
              columns: [
                %{key: "avg", label: gettext("Average"), style: "line", metric: "avg"},
                %{key: "max", label: gettext("Peak"), style: "band"}
              ]
            }
          }
          class="h-72"
        >
          <:note>
            {gettext("Shaded: no data (our collection wasn't running). Breaks: offline.")}
          </:note>
        </.chart>
      </div>
      <.chart
        id="followers-chart"
        refresh={@refresh}
        kind="timeseries"
        title={gettext("Followers")}
        metric={:followers}
        src={"/data/v1/channels/#{@channel.slug}/followers?#{@query}"}
        opts={
          %{
            zero: false,
            columns: [%{key: "v", label: gettext("Followers"), style: "line", metric: "followers"}]
          }
        }
        class="h-72"
      />
      <.chart
        id="heatmap-chart"
        refresh={@refresh}
        kind="heatmap"
        title={gettext("When they stream (avg viewers, %{tz})", tz: @channel.timezone)}
        icon="hero-calendar-days"
        src={"/data/v1/channels/#{@channel.slug}/heatmap?#{@query}"}
        opts={%{unit: gettext("avg viewers")}}
        class="h-64"
      />
      <.chart
        id="categories-chart"
        refresh={@refresh}
        kind="share"
        title={gettext("Hours watched by category")}
        icon="hero-squares-2x2"
        src={"/data/v1/channels/#{@channel.slug}/categories?#{@query}"}
        opts={
          %{
            label: gettext("Category"),
            valueLabel: gettext("Hours watched"),
            otherLabel: gettext("Other")
          }
        }
        class="h-64"
      />
      <section id="records" class="card-surface p-4 sm:p-5">
        <h2 class="flex items-center gap-3 text-[0.9375rem] font-semibold">
          <.icon_tile icon="hero-trophy" />{gettext("Records")}
        </h2>
        <div class="mt-3 grid gap-0.5">
          <.record
            :if={r = @records.peak}
            metric={:peak}
            label={gettext("Highest peak")}
            to={~p"/c/#{@channel.slug}/streams/#{r.stream_id}"}
            at={r.started_at}
            tz={@channel.timezone}
          >
            <.num value={r.peak_viewers} />
          </.record>
          <.record
            :if={r = @records.hours_watched}
            metric={:hw}
            label={gettext("Most hours watched")}
            to={~p"/c/#{@channel.slug}/streams/#{r.stream_id}"}
            at={r.started_at}
            tz={@channel.timezone}
          >
            <.num value={r.hours_watched} compact />
          </.record>
          <.record
            :if={r = @records.longest}
            metric={:airtime}
            label={gettext("Longest stream")}
            to={~p"/c/#{@channel.slug}/streams/#{r.stream_id}"}
            at={r.started_at}
            tz={@channel.timezone}
          >
            <.duration seconds={r.airtime_s} />
          </.record>
        </div>
        <p :if={@records.peak == nil} class="text-sm text-muted">{gettext("No streams yet.")}</p>
      </section>
    </div>

    <.weekdays days={@weekdays} tz={@channel.timezone} />

    <section class="mt-6">
      <div class="flex items-center gap-3">
        <.icon_tile metric={:airtime} />
        <h2 class="text-lg font-semibold tracking-tight">{gettext("Recent streams")}</h2>
        <span class="flex-1"></span>
        <.link
          patch={page_path(@channel, :streams, Period.to_params(@period))}
          class="btn btn-sm btn-ghost border-base-300"
        >
          {gettext("All streams")}<.icon name="hero-arrow-right-micro" class="size-4 rtl:rotate-180" />
        </.link>
      </div>
      <.stream_table streams={@stream_rows} channel={@channel} params={@params} sortable={false} />
    </section>
    """
  end

  defp render_tab(%{live_action: :streams} = assigns) do
    ~H"""
    <form id="category-filter" phx-change="filter" class="flex items-center gap-2 text-sm">
      <label for="category-select" class="opacity-70">{gettext("Category")}</label>
      <select id="category-select" name="category" class="select select-sm w-56">
        <option value="">{gettext("All")}</option>
        <option :for={{id, name} <- @categories} value={id} selected={@category_id == id}>
          {name}
        </option>
      </select>
      <span class="opacity-60">{ngettext("1 stream", "%{count} streams", length(@stream_rows))}</span>
    </form>
    <.stream_table streams={@stream_rows} channel={@channel} params={@params} sortable={true} />
    """
  end

  defp render_tab(%{live_action: :chat} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-xs opacity-80">
      <.coverage_badge fraction={@coverage} label={gettext("chat coverage")} />
      <span>{gettext("No message text is ever stored: only who chatted, when, and how much.")}</span>
    </div>
    <section class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
      <.kpi
        label={gettext("Messages")}
        metric={:chat}
        value={@kpis.now.messages}
        previous={@kpis.before.messages}
      />
      <.kpi
        label={gettext("Unique chatters")}
        metric={:chat}
        value={@kpis.now.unique_chatters}
        previous={@kpis.before.unique_chatters}
      />
      <.kpi
        label={gettext("Messages per hour live")}
        metric={:chat}
        value={per_hour(@kpis.now.messages, @kpis.now.airtime_s)}
        previous={per_hour(@kpis.before.messages, @kpis.before.airtime_s)}
      />
      <.kpi
        label={gettext("Chatters per 100 viewers")}
        metric={:chat}
        value={engagement(@kpis.now)}
        previous={engagement(@kpis.before)}
        hint={gettext("Unique chatters in the period ÷ average viewers × 100")}
      />
    </section>
    <div class="mt-4">
      <.chart
        id="chat-chart"
        refresh={@refresh}
        kind="timeseries"
        title={gettext("Messages")}
        metric={:chat}
        src={"/data/v1/channels/#{@channel.slug}/chat?#{@query}"}
        opts={
          %{columns: [%{key: "messages", label: gettext("Messages"), style: "bar", metric: "chat"}]}
        }
        class="h-72"
      >
        <:note>{gettext("Active chatters in a rolling window are on each stream's page.")}</:note>
      </.chart>
    </div>
    <section class="card-surface mt-4 overflow-x-auto p-4">
      <h2 class="text-sm font-semibold">{gettext("New and returning chatters")}</h2>
      <p class="text-xs opacity-60">
        {gettext("New: chatting in this channel for the first time since we started tracking it.")}
      </p>
      <table id="retention" class="table table-sm mt-2">
        <thead>
          <tr>
            <th>{gettext("Stream")}</th><th class="text-end">{gettext("Chatters")}</th><th class="text-end">
              {gettext("New")}
            </th><th class="text-end">{gettext("Returning")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- Enum.reverse(@retention)}>
            <td>
              <.link
                navigate={~p"/c/#{@channel.slug}/streams/#{r.stream_id}"}
                class="whitespace-nowrap hover:underline"
              ><.time at={r.started_at} fmt="short" tz={@channel.timezone} /></.link>
            </td>
            <td class="text-end"><.num value={r.chatters} /></td>
            <td class="text-end"><.num value={r.new} /></td>
            <td class="text-end"><.num value={r.returning} /></td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp render_tab(%{live_action: :support} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-xs opacity-80">
      <.coverage_badge fraction={@ingress} label={gettext("webhook coverage")} />
      <span :if={@ingress == 0}>
        {gettext(
          "We weren't receiving this channel's events in this period, so these figures are unknown."
        )}
      </span>
    </div>
    <section id="support-kpis" class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-5">
      <.kpi label={gettext("New subs")} metric={:subs} value={known(@support.subs, @ingress)} />
      <.kpi label={gettext("Renewals")} metric={:subs} value={known(@support.resubs, @ingress)} />
      <.kpi
        label={gettext("Gifted subs")}
        metric={:subs}
        value={known(@support.gifted_subs, @ingress)}
      />
      <.kpi label={gettext("Kicks")} metric={:subs} value={known(@support.kicks, @ingress)} />
      <div class="card-surface stat-card m-subs p-4 sm:px-5">
        <div class="flex items-center gap-2">
          <.icon_tile metric={:subs} icon="hero-banknotes" size={:sm} />
          <span class="text-[0.8125rem] font-medium text-muted">{gettext("Revenue")}</span>
          <.estimate />
        </div>
        <div class="mt-3 text-2xl font-bold tracking-tight tabular-nums sm:text-[1.75rem] sm:leading-8">
          $<.num
            value={known(Float.round(@support.estimated_revenue_usd, 0), @ingress)}
            compact
          />
        </div>
        <div class="mt-2 text-xs text-muted">
          {gettext("subs at $%{p}, %{s}% share; a Kick at $%{k}",
            p: @support.assumptions["sub_price_usd"],
            s: round(@support.assumptions["sub_share"] * 100),
            k: @support.assumptions["kick_value_usd"]
          )}
        </div>
      </div>
    </section>
    <div class="mt-4">
      <.chart
        id="support-chart"
        refresh={@refresh}
        kind="bars"
        title={gettext("Support")}
        metric={:subs}
        src={"/data/v1/channels/#{@channel.slug}/support?#{@query}"}
        opts={
          %{
            columns: [
              %{key: "subs", label: gettext("Subs"), stack: "s", metric: "subs"},
              %{key: "gifts", label: gettext("Gifted subs"), stack: "s"}
            ]
          }
        }
        class="h-64"
      />
    </div>
    <div class="mt-4 grid gap-4 md:grid-cols-2">
      <.people_table
        id="top-gifters"
        title={gettext("Top gifters")}
        people={@support.top_gifters}
        unit={gettext("subs gifted")}
      />
      <.people_table
        id="top-kicks"
        title={gettext("Top Kick senders")}
        people={@support.top_kicks}
        unit={gettext("Kicks")}
      />
    </div>
    """
  end

  defp render_tab(%{live_action: :categories} = assigns) do
    ~H"""
    <div class="grid gap-4 lg:grid-cols-3">
      <.chart
        id="categories-share"
        refresh={@refresh}
        kind="share"
        title={gettext("Hours watched by category")}
        icon="hero-squares-2x2"
        src={"/data/v1/channels/#{@channel.slug}/categories?#{@query}"}
        opts={
          %{
            label: gettext("Category"),
            valueLabel: gettext("Hours watched"),
            otherLabel: gettext("Other")
          }
        }
        class="h-72"
      />
      <div class="card-surface overflow-x-auto lg:col-span-2">
        <table id="category-table" class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Category")}</th>
              <th class="text-end">{gettext("Hours watched")}</th>
              <th class="text-end">{gettext("Share")}</th>
              <th class="text-end">{gettext("Airtime")}</th>
              <th class="text-end">{gettext("Avg viewers")}</th>
              <th
                class="text-end"
                title={
                  gettext(
                    "Average viewers in the 15 minutes after switching to it, minus the 15 before"
                  )
                }
              >
                {gettext("After switching")}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @categories}>
              <td>
                <.link :if={c.name} navigate={~p"/category/#{Reports.slugify(c.name)}"} class="link">{c.name}</.link>
              </td>
              <td class="text-end"><.num value={c.hours_watched} /></td>
              <td class="text-end tabular-nums">
                {c.share && "#{:erlang.float_to_binary(c.share * 100, decimals: 1)}%"}
              </td>
              <td class="text-end"><.duration seconds={c.airtime_s} /></td>
              <td class="text-end"><.num value={c.avg_viewers} /></td>
              <td class="text-end tabular-nums">
                <%= if c.switch_change do %>
                  <span class={if c.switch_change >= 0, do: "text-success", else: "text-error"}>{if c.switch_change >=
                                                                                                      0,
                                                                                                    do:
                                                                                                      "+"}<.num value={
                    c.switch_change
                  } /></span>
                  <span class="text-xs opacity-60">({c.switches}×)</span>
                <% else %>
                  –
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :metric, :atom, required: true
  attr :label, :string, required: true
  attr :to, :string, required: true
  attr :at, :any, required: true
  attr :tz, :string, required: true
  slot :inner_block, required: true

  defp record(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class="flex items-center gap-3 rounded-field px-2 py-2 transition-colors hover:bg-[var(--surface-hover)]"
    >
      <.icon_tile metric={@metric} size={:sm} />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm text-muted">{@label}</span>
        <span class="block text-xs text-subtle"><.time at={@at} fmt="date" tz={@tz} /></span>
      </span>
      <span class="text-base font-bold tabular-nums">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  attr :days, :list, required: true
  attr :tz, :string, required: true

  # Weekday bars: hours watched, average viewers and airtime, each against
  # its own busiest weekday. An unknown figure has no bar and shows "–".
  defp weekdays(assigns) do
    ~H"""
    <section id="weekdays" class="card-surface mt-4 p-4 sm:p-5">
      <h2 class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[0.9375rem] font-semibold">
        <.icon_tile icon="hero-calendar-days" />{gettext("Days of the week")}
        <span class="text-xs font-normal text-muted">
          {gettext("totals over the period, in %{tz} time", tz: @tz)}
        </span>
      </h2>
      <div class="mt-4 grid gap-3 md:grid-cols-3">
        <.day_bars
          metric={:hw}
          title={gettext("Hours watched")}
          days={@days}
          key={:hours_watched}
        />
        <.day_bars metric={:avg} title={gettext("Average viewers")} days={@days} key={:avg_viewers} />
        <.day_bars metric={:airtime} title={gettext("Airtime")} days={@days} key={:airtime_s} />
      </div>
    </section>
    """
  end

  attr :metric, :atom, required: true
  attr :title, :string, required: true
  attr :days, :list, required: true
  attr :key, :atom, required: true

  defp day_bars(assigns) do
    max =
      assigns.days
      |> Enum.map(&Map.get(&1, assigns.key))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    assigns = assign(assigns, max: max)

    ~H"""
    <div class={["inset-well p-4", "m-#{@metric}"]}>
      <h3 class="mb-3 text-[0.8125rem] font-semibold text-muted">{@title}</h3>
      <div
        :for={d <- @days}
        class="grid h-6 grid-cols-[2.25rem_1fr_auto] items-center gap-2 text-[0.8125rem]"
      >
        <span class="font-medium text-muted">{weekday_label(d.weekday)}</span>
        <span class="day-bar">
          <span
            :if={is_number(Map.get(d, @key)) and is_number(@max) and @max > 0}
            style={"width: #{Float.round(Map.get(d, @key) / @max * 100, 1)}%"}
          ></span>
        </span>
        <span class="min-w-12 text-end font-semibold tabular-nums">
          <%= if @key == :airtime_s do %>
            <.duration seconds={Map.get(d, @key)} />
          <% else %>
            <.num value={Map.get(d, @key)} compact />
          <% end %>
        </span>
      </div>
    </div>
    """
  end

  defp weekday_label(1), do: gettext("Mon")
  defp weekday_label(2), do: gettext("Tue")
  defp weekday_label(3), do: gettext("Wed")
  defp weekday_label(4), do: gettext("Thu")
  defp weekday_label(5), do: gettext("Fri")
  defp weekday_label(6), do: gettext("Sat")
  defp weekday_label(7), do: gettext("Sun")

  attr :streams, :list
  attr :channel, :map
  attr :params, :map
  attr :sortable, :boolean

  defp stream_table(assigns) do
    ~H"""
    <div class="card-surface mt-3 overflow-x-auto">
      <table id="streams" class="table table-sm">
        <thead>
          <tr>
            <th><.col_head {assigns} key="started_at" label={gettext("Date")} /></th>
            <th>{gettext("Category")}</th>
            <th class="text-end">
              <.col_head {assigns} key="airtime_s" label={gettext("Duration")} />
            </th>
            <th class="text-end"><.col_head {assigns} key="avg_viewers" label={gettext("Avg")} /></th>
            <th class="text-end">
              <.col_head {assigns} key="peak_viewers" label={gettext("Peak")} />
            </th>
            <th class="text-end">
              <.col_head {assigns} key="hours_watched" label={gettext("Hours watched")} />
            </th>
            <th class="text-end">
              <.col_head {assigns} key="follower_gain" label={gettext("Followers")} />
            </th>
            <th class="text-end">
              <.col_head {assigns} key="unique_chatters" label={gettext("Chatters")} />
            </th>
            <th class="text-end">{gettext("Subs + gifts")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @streams} id={"stream-#{s.id}"} class={s.excluded? && "opacity-70"}>
            <td>
              <.link
                navigate={~p"/c/#{@channel.slug}/streams/#{s.id}"}
                class="whitespace-nowrap font-medium hover:underline"
              ><.time at={s.started_at} fmt="short" tz={@channel.timezone} /></.link>
              <span :if={is_nil(s.ended_at)} class="ms-1"><.live_badge /></span>
              <span
                :if={s.excluded?}
                class="badge badge-ghost badge-xs ms-1"
                title={gettext("Left out of statistics")}
              >{gettext("excluded")}</span>
            </td>
            <td class="max-w-48 truncate">{s.category}</td>
            <td class="text-end"><.duration seconds={s.airtime_s} /></td>
            <td class="text-end"><.num value={s.avg_viewers} /></td>
            <td class="text-end"><.num value={s.peak_viewers} /></td>
            <td class="text-end"><.num value={s.hours_watched} compact /></td>
            <td class="text-end"><.num value={s.follower_gain} /></td>
            <td class="text-end"><.num value={s.unique_chatters} /></td>
            <td class="text-end">
              <.num value={known_sum([s.subs, s.resubs, s.gifted_subs])} />
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@streams == []} class="p-6 text-center text-sm text-base-content/60">
        {gettext("No streams in this period.")}
      </p>
    </div>
    """
  end

  defp col_head(assigns) do
    ~H"""
    <%= if @sortable do %>
      <.sort_link channel={@channel} params={@params} key={@key} label={@label} />
    <% else %>
      {@label}
    <% end %>
    """
  end

  attr :id, :string
  attr :title, :string
  attr :people, :list
  attr :unit, :string

  defp people_table(assigns) do
    ~H"""
    <section id={@id} class="card-surface p-4">
      <h2 class="text-sm font-semibold">{@title}</h2>
      <ol class="mt-2 space-y-1 text-sm">
        <li :for={p <- @people} class="flex gap-2">
          <span class="flex-1 truncate">{p.name || gettext("user %{id}", id: p.user_id)}</span>
          <span><.num value={p.total} /> <span class="text-xs opacity-60">{@unit}</span></span>
        </li>
      </ol>
      <p :if={@people == []} class="text-sm opacity-60">{gettext("Nobody in this period.")}</p>
    </section>
    """
  end

  @impl true
  def handle_event("filter", %{"category" => category}, socket) when is_binary(category) do
    params =
      if category == "",
        do: Map.delete(socket.assigns.params, "category"),
        else: Map.put(socket.assigns.params, "category", category)

    {:noreply, push_patch(socket, to: page_path(socket.assigns.channel, :streams, params))}
  end

  # The custom range's days are the channel's (§13.6).
  def handle_event("custom_range", form, socket) do
    %{channel: channel, live_action: action, params: params} = socket.assigns

    case PageParams.custom_range(form["from"], form["to"], channel.timezone) do
      {:ok, range} ->
        params = params |> Map.delete("period") |> Map.merge(range)
        {:noreply, push_patch(socket, to: page_path(channel, action, params))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp per_hour(nil, _), do: nil
  defp per_hour(_, s) when s in [nil, 0], do: nil
  defp per_hour(messages, airtime_s), do: messages / (airtime_s / 3600)

  defp engagement(%{unique_chatters: c, avg_viewers: v})
       when is_number(v) and v > 0 and is_integer(c),
       do: c / v * 100

  defp engagement(_), do: nil
end
