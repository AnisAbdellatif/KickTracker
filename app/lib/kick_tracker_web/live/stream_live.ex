defmodule KickTrackerWeb.StreamLive do
  @moduledoc """
  The stream page (project.md §13.3): the richest chart (viewers with
  category bands, title ticks and markers; chat; support, on one time
  axis), stat cards, the change timeline, top chatters and supporters.

  While the stream is live, each new reading is pushed to the chart hook
  (`chart:append`) and the cards update; the chart's history is never
  kept in the LiveView's assigns (§13.5).
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
       |> assign(channel: channel, stream: stream, now_viewers: nil)
       |> assign(
         page_title: "#{channel.slug} · #{Calendar.strftime(stream.started_at, "%Y-%m-%d")}"
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

  @impl true
  def handle_info({:viewers, %{at: at, viewers: v}}, socket) do
    {:noreply,
     socket
     |> assign(now_viewers: v)
     |> push_event("chart:append", %{
       id: "stream-chart",
       t: DateTime.to_unix(at),
       values: %{avg: v, max: v}
     })}
  end

  def handle_info({:changes, _}, socket), do: {:noreply, load(socket)}

  def handle_info({:stream_ended, _, _}, socket) do
    {:noreply, socket |> assign(stream: Reports.stream(socket.assigns.stream.id)) |> load()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="stream-page" phx-hook="Format">
        <nav class="text-sm opacity-70">
          <.link navigate={~p"/c/#{@channel.slug}"} class="link">{@channel.slug}</.link>
          /
          <.link navigate={~p"/c/#{@channel.slug}/streams"} class="link">{gettext("Streams")}</.link>
        </nav>
        <header class="mt-1 flex flex-wrap items-center gap-3">
          <h1 class="text-2xl font-semibold tracking-tight">
            <.time at={@stream.started_at} tz={@channel.timezone} />
          </h1>
          <%= if is_nil(@stream.ended_at) do %>
            <.live_badge />
            <span :if={@now_viewers} class="text-lg"><.num value={@now_viewers} />
            <span class="text-sm opacity-70">{gettext("watching")}</span></span>
          <% else %>
            <span class="text-sm opacity-70">
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
            type="button"
            class="btn btn-ghost btn-xs"
            aria-pressed="false"
          >{gettext("Channel time")}</button>
        </header>

        <section
          :if={s = @stream.stats}
          id="stream-cards"
          class="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-8"
        >
          <.kpi label={gettext("Duration")} value={s.airtime_s} kind={:duration} />
          <.kpi label={gettext("Avg viewers")} value={s.avg_viewers} />
          <.kpi label={gettext("Peak")} value={s.peak_viewers} />
          <.kpi label={gettext("Hours watched")} value={s.hours_watched} />
          <.kpi label={gettext("Follower gain")} value={s.follower_gain} />
          <.kpi label={gettext("Unique chatters")} value={s.unique_chatters} />
          <.kpi label={gettext("Messages")} value={s.messages} />
          <.kpi label={gettext("Subs + gifts")} value={s.subs + s.resubs + s.gifted_subs} />
        </section>

        <div class="mt-4">
          <.chart
            id="stream-chart"
            kind="stream"
            src={"/data/v1/streams/#{@stream.id}"}
            chatters_src={"/data/v1/streams/#{@stream.id}/chatters"}
            opts={%{window: 5, labels: labels()}}
            class="h-[34rem]"
          >
            <:controls>
              <label class="flex items-center gap-1 text-xs">
                {gettext("Active chatters over")}
                <select data-chart-window class="select select-xs w-20" aria-label={gettext("Window")}>
                  <option :for={w <- [5, 10, 15]} value={w} selected={w == 5}>{w} min</option>
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
          <section class="rounded-box border border-base-300 p-3">
            <h2 class="font-medium">{gettext("Title and category")}</h2>
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
            <section class="rounded-box border border-base-300 p-3">
              <h2 class="font-medium">{gettext("Top chatters")}</h2>
              <ol id="top-chatters" class="mt-2 space-y-1 text-sm">
                <li :for={p <- @people.chatters} class="flex gap-2">
                  <span class="flex-1 truncate">{p.name || gettext("user %{id}", id: p.user_id)}</span>
                  <span><.num value={p.count} />
                  <span class="text-xs opacity-60">{gettext("messages")}</span></span>
                </li>
              </ol>
            </section>
            <section class="rounded-box border border-base-300 p-3">
              <h2 class="font-medium">{gettext("Top supporters")}</h2>
              <ol id="top-supporters" class="mt-2 space-y-1 text-sm">
                <li :for={p <- @people.supporters} class="flex gap-2">
                  <span class="flex-1 truncate">{p.name || gettext("user %{id}", id: p.user_id)}</span>
                  <span :if={p.gifts > 0}><.num value={p.gifts} />
                  <span class="text-xs opacity-60">{gettext("gifted")}</span></span>
                  <span :if={p.kicks > 0}><.num value={p.kicks} />
                  <span class="text-xs opacity-60">Kicks</span></span>
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
      flagged: gettext("flagged reading, not counted as a peak")
    }
  end
end
