defmodule KickTrackerWeb.StreamLive do
  @moduledoc """
  The stream page (project.md §13.3): the richest chart (viewers with
  category bands, title ticks and markers; chat; support, on one time
  axis), stat cards, the change timeline, top chatters and supporters.

  While the stream is live, each new reading is pushed to the chart hook
  (`chart:append`) and the cards (a few numbers) are read again at most
  once a minute; the chart's history is never kept in the LiveView's
  assigns (§13.5). The channel's readings carry no stream id, so once
  this stream has ended the page stops listening: a later stream's
  readings never reach this one's chart.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Channels, Reports, Settings}
  alias KickTracker.Tracking.ChannelServer

  @impl true
  def mount(%{"slug" => slug, "id" => id}, _session, socket) do
    with {id, ""} <- Integer.parse(id),
         %{} = stream <- Reports.stream(id),
         %{public: true} = channel <- Channels.get!(stream.channel_id),
         true <-
           String.downcase(channel.slug) == String.downcase(slug) or
             Reports.channel_by_slug(slug) == channel,
         {:merged, nil} <- {:merged, stream.merged_into} do
      if connected?(socket) and is_nil(stream.ended_at),
        do: Phoenix.PubSub.subscribe(KickTracker.PubSub, ChannelServer.topic(channel.id))

      {:ok,
       socket
       |> assign(channel: channel, stream: stream, now_viewers: nil, stats_at: DateTime.utc_now())
       |> assign(
         page_title: "#{channel.slug} · #{Calendar.strftime(stream.started_at, "%Y-%m-%d")}",
         page_description:
           gettext("A stream of %{channel}: viewers, chat and support minute by minute.",
             channel: channel.slug
           )
       )
       |> load()}
    else
      # Merged into an earlier stream: show that one.
      {:merged, merged_into} ->
        {:ok, push_navigate(socket, to: ~p"/c/#{slug}/streams/#{merged_into}")}

      _ ->
        raise KickTrackerWeb.NotFoundError, "no such stream"
    end
  end

  defp load(socket) do
    stream = socket.assigns.stream

    assign(socket,
      timeline: timeline(stream),
      people: if(Settings.get("top_people_public"), do: Reports.top_people(stream), else: nil)
    )
  end

  defp timeline(stream) do
    t = Reports.timeline(stream)

    (Enum.map(t.segments, &%{at: DateTime.from_unix!(&1.from), kind: :category, value: &1.name}) ++
       Enum.map(t.titles, &%{at: DateTime.from_unix!(&1.at), kind: :title, value: &1.title}))
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @stats_every_s 55

  @impl true
  def handle_info({:viewers, %{at: at, viewers: v}}, socket) do
    if is_nil(socket.assigns.stream.ended_at) do
      {:noreply,
       socket
       |> assign(now_viewers: v)
       |> refresh_stats(at)
       |> push_event("chart:append", %{
         id: "stream-chart",
         t: DateTime.to_unix(at),
         values: %{avg: v, max: v}
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:changes, _}, socket), do: {:noreply, load(socket)}

  # This stream ended, or another one started (which means this one is
  # over): read it again, and stop listening once it is closed.
  def handle_info({event, _, _}, socket) when event == :stream_ended, do: reread(socket)
  def handle_info({:stream_started, _}, socket), do: reread(socket)

  def handle_info(_other, socket), do: {:noreply, socket}

  defp reread(socket) do
    stream = Reports.stream(socket.assigns.stream.id) || socket.assigns.stream

    if stream.ended_at,
      do:
        Phoenix.PubSub.unsubscribe(
          KickTracker.PubSub,
          ChannelServer.topic(socket.assigns.channel.id)
        )

    {:noreply, socket |> assign(stream: stream) |> load()}
  end

  # The cards while live: small scalars, read again at most once a minute
  # of readings.
  defp refresh_stats(socket, at) do
    if DateTime.diff(at, socket.assigns.stats_at) >= @stats_every_s do
      case Reports.stream(socket.assigns.stream.id) do
        nil ->
          socket

        stream ->
          assign(socket,
            stream: %{socket.assigns.stream | stats: stream.stats},
            stats_at: at
          )
      end
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="stream-page" phx-hook="Format">
        <nav
          class="flex items-center gap-1 text-sm text-base-content/60"
          aria-label={gettext("Breadcrumb")}
        >
          <.link
            navigate={~p"/c/#{@channel.slug}"}
            class="flex items-center gap-1.5 hover:text-base-content"
          >
            <.avatar name={@channel.slug} class="size-5 text-[0.65rem]" />{@channel.slug}
          </.link>
          <.icon name="hero-chevron-right-micro" class="size-4 opacity-50 rtl:rotate-180" />
          <.link navigate={~p"/c/#{@channel.slug}/streams"} class="hover:text-base-content">
            {gettext("Streams")}
          </.link>
        </nav>
        <header class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-2">
          <h1 class="text-2xl font-semibold tracking-tight sm:text-3xl">
            <.time at={@stream.started_at} tz={@channel.timezone} />
          </h1>
          <%= if is_nil(@stream.ended_at) do %>
            <.live_badge />
            <span :if={@now_viewers} class="text-sm text-base-content/60">
              <.num value={@now_viewers} class="text-lg font-semibold text-base-content" />
              {gettext("watching")}
            </span>
          <% else %>
            <span class="text-sm text-base-content/60">
              {gettext("ended")} <.time at={@stream.ended_at} fmt="time" tz={@channel.timezone} />
              <span
                :if={@stream.end_source == "poll"}
                title={
                  gettext("Kick's end event was missed; the end is when polling last saw it live")
                }
              >*</span>
            </span>
          <% end %>
          <span :if={@stream.excluded?} class="badge badge-warning badge-sm">{gettext(
            "excluded from statistics"
          )}</span>
          <span class="flex-1"></span>
          <button
            id="tz-switch"
            phx-hook="TzSwitch"
            phx-update="ignore"
            type="button"
            class="btn btn-ghost btn-sm aria-pressed:btn-active"
            aria-pressed="false"
            aria-label={gettext("Channel time")}
          >
            <.icon name="hero-globe-alt-micro" class="size-4" />
            <span class="hidden sm:inline">{gettext("Channel time")}</span>
          </button>
        </header>

        <section
          :if={s = @stream.stats}
          id="stream-cards"
          class="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4 xl:grid-cols-8"
        >
          <.kpi label={gettext("Duration")} value={s.airtime_s} kind={:duration} />
          <.kpi label={gettext("Avg viewers")} value={s.avg_viewers} />
          <.kpi label={gettext("Peak")} value={s.peak_viewers} />
          <.kpi label={gettext("Hours watched")} value={s.hours_watched} />
          <.kpi label={gettext("Follower gain")} value={s.follower_gain} />
          <.kpi label={gettext("Unique chatters")} value={s.unique_chatters} />
          <.kpi label={gettext("Messages")} value={s.messages} />
          <.kpi label={gettext("Subs + gifts")} value={known_sum([s.subs, s.resubs, s.gifted_subs])} />
        </section>

        <div class="mt-4">
          <.chart
            id="stream-chart"
            kind="stream"
            refresh={if(is_nil(@stream.ended_at), do: 60)}
            src={"/data/v1/streams/#{@stream.id}"}
            chatters_src={"/data/v1/streams/#{@stream.id}/chatters"}
            opts={%{window: 5, labels: labels()}}
            class="h-[34rem]"
          >
            <:controls>
              <label class="flex items-center gap-1 text-xs">
                {gettext("Active chatters over")}
                <select data-chart-window class="select select-xs w-20" aria-label={gettext("Window")}>
                  <option :for={w <- [5, 10, 15]} value={w} selected={w == 5}>
                    {gettext("%{n} min", n: w)}
                  </option>
                </select>
              </label>
            </:controls>
            <:note>
              {gettext(
                "Bands: categories. Dotted lines: title changes. Markers: gift bursts, big Kicks, raids. Grey: no data."
              )}
            </:note>
          </.chart>
        </div>

        <div class="mt-4 grid gap-4 lg:grid-cols-3">
          <section class="card-surface p-4">
            <h2 class="text-sm font-semibold">{gettext("Title and category")}</h2>
            <ol id="timeline" class="mt-2 space-y-2 text-sm">
              <li :for={e <- @timeline} class="flex gap-2">
                <span class="w-14 shrink-0 text-xs opacity-60"><.time
                  at={e.at}
                  fmt="time"
                  tz={@channel.timezone}
                /></span>
                <span :if={e.kind == :category} class="badge badge-outline badge-sm">{e.value}</span>
                <span :if={e.kind == :title} class="break-words">{e.value}</span>
              </li>
            </ol>
          </section>
          <%= if @people do %>
            <section class="card-surface p-4">
              <h2 class="text-sm font-semibold">{gettext("Top chatters")}</h2>
              <ol id="top-chatters" class="mt-2 space-y-1 text-sm">
                <li :for={p <- @people.chatters} class="flex gap-2">
                  <span class="flex-1 truncate">{p.name || gettext("user %{id}", id: p.user_id)}</span>
                  <span><.num value={p.count} />
                  <span class="text-xs opacity-60">{gettext("messages")}</span></span>
                </li>
              </ol>
            </section>
            <section class="card-surface p-4">
              <h2 class="text-sm font-semibold">{gettext("Top supporters")}</h2>
              <ol id="top-supporters" class="mt-2 space-y-1 text-sm">
                <li :for={p <- @people.supporters} class="flex gap-2">
                  <span class="flex-1 truncate">{p.name || gettext("user %{id}", id: p.user_id)}</span>
                  <span :if={p.gifts > 0}><.num value={p.gifts} />
                  <span class="text-xs opacity-60">{gettext("gifted")}</span></span>
                  <span :if={p.kicks > 0}><.num value={p.kicks} />
                  <span class="text-xs opacity-60">{gettext("Kicks")}</span></span>
                  <span :if={p.subs > 0 and p.gifts == 0 and p.kicks == 0} class="text-xs opacity-60">{gettext(
                    "subscribed"
                  )}</span>
                </li>
              </ol>
            </section>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp labels do
    %{
      viewers: gettext("Viewers"),
      messages: gettext("Messages / min"),
      chatters: gettext("Active chatters"),
      subs: gettext("Subs"),
      gifts: gettext("Gifted subs"),
      gifted: gettext("gifted subs"),
      flagged: gettext("flagged reading, not counted as a peak"),
      kicks: gettext("Kicks"),
      kinds: event_labels(),
      event: event_label(nil),
      title: gettext("Title"),
      category: gettext("Category")
    }
  end
end
