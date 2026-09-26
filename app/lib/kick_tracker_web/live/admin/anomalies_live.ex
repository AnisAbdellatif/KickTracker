defmodule KickTrackerWeb.Admin.AnomaliesLive do
  @moduledoc """
  Audience anomalies (project.md §19.4), admin only: for one channel, its
  latest streams with what `Metrics.Anomalies` found in each; for one
  stream, the findings with their figures, the stream's chart with them
  shaded, and its figures against the channel's usual ones.

  Signs for review, never a verdict: nothing here reaches the public site.

  A stream still live is read again every minute (its findings, and the
  chart's data), so the page follows it as it goes; once it has ended the
  page stops.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Anomalies, Channels, Reports}

  @refresh_ms 60_000

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Anomalies"))}

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {id, ""} <- Integer.parse(params["id"] || ""),
         %{} = stream <- Reports.stream(id),
         channel = Channels.get!(stream.channel_id),
         %{} = result <- Anomalies.stream(channel, id) do
      {:noreply,
       socket
       |> assign(channel: channel, stream: stream, result: result)
       |> schedule(is_nil(stream.ended_at))}
    else
      _ -> raise KickTrackerWeb.NotFoundError, "no such stream"
    end
  end

  def handle_params(params, _uri, socket) do
    channels = Channels.list_all()

    channel =
      Enum.find(channels, &(to_string(&1.id) == params["channel"])) || List.first(channels)

    results = if(channel, do: Anomalies.channel_streams(channel), else: [])

    {:noreply,
     socket
     |> assign(channels: channels, channel: channel, results: results)
     |> schedule(Enum.any?(results, &is_nil(&1.stream.ended_at)))}
  end

  # Read again in a minute while a stream shown is live: its findings move
  # as it goes. One timer at a time, whatever the page was patched to.
  defp schedule(socket, live?) do
    if ref = socket.assigns[:refresh_ref], do: Process.cancel_timer(ref)
    ref = if live? and connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    assign(socket, refresh_ref: ref)
  end

  @impl true
  def handle_info({KickTrackerWeb.Admin.ChannelPicker, "anomalies-channel", id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/admin/anomalies?channel=#{id}")}

  def handle_info(:refresh, %{assigns: %{live_action: :show}} = socket) do
    params = %{"id" => to_string(socket.assigns.stream.id)}
    handle_params(params, nil, assign(socket, refresh_ref: nil))
  end

  def handle_info(:refresh, socket) do
    params = %{"channel" => socket.assigns.channel && to_string(socket.assigns.channel.id)}
    handle_params(params, nil, assign(socket, refresh_ref: nil))
  end

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:anomalies}>
      <div id="anomaly-page" phx-hook="Format" class="space-y-6">
        <.link
          navigate={~p"/admin/anomalies?channel=#{@channel.id}"}
          class="text-muted inline-flex items-center gap-1 text-sm hover:text-base-content"
        >
          <.icon name="hero-arrow-left" class="size-4" />{gettext("All streams of this channel")}
        </.link>
        <.page_header title={@channel.slug} icon="hero-exclamation-triangle">
          <:subtitle>
            <.time at={@stream.started_at} /> ·
            <.status_pill tone={level_tone(@result.level)}>{level_label(@result.level)}</.status_pill>
          </:subtitle>
        </.page_header>

        <.review_note />

        <.chart
          id="anomaly-chart"
          kind="stream"
          src={~p"/admin/anomalies/#{@stream.id}/chart"}
          refresh={if is_nil(@stream.ended_at), do: 60}
          opts={%{labels: chart_labels()}}
          class="h-[30rem]"
          title={gettext("Viewers and chat, findings shaded")}
        />

        <.panel title={gettext("Findings")} icon="hero-magnifying-glass">
          <p :if={@result.findings == []} class="text-muted text-sm">
            {gettext("Nothing stood out in what we observed.")}
          </p>
          <ul id="findings" class="space-y-3">
            <li :for={f <- @result.findings} class="inset-well p-3">
              <div class="flex flex-wrap items-center gap-2 text-sm">
                <.status_pill tone={:warn}>{label(f.kind)}</.status_pill>
                <span class="text-muted"><.time at={f.from} /> – <.time at={f.to} fmt="time" /></span>
              </div>
              <p class="mt-1.5 text-sm">{describe(f)}</p>
            </li>
          </ul>
        </.panel>

        <.panel title={gettext("This stream against the channel's usual")} icon="hero-scale" flush>
          <table id="profile" class="table table-sm">
            <thead>
              <tr>
                <th></th><th>{gettext("This stream")}</th><th>
                  {gettext("Usual (median of %{n} earlier streams)", n: @result.baseline.streams)}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>{gettext("Chatters per minute per 100 viewers")}</td>
                <td>{per_hundred(@result.profile.engagement)}</td>
                <td>{per_hundred(@result.baseline.engagement)}</td>
              </tr>
              <tr>
                <td>{gettext("Typical change between readings")}</td>
                <td>{pct(@result.profile.noise, 2)}</td>
                <td>{pct(@result.baseline.noise, 2)}</td>
              </tr>
              <tr>
                <td>{gettext("First readings, share of the level after 15 minutes")}</td>
                <td>{pct(@result.profile.start_share, 0)}</td>
                <td>{pct(@result.baseline.start_share, 0)}</td>
              </tr>
              <tr>
                <td>{gettext("Follows per 1 000 hours watched")}</td>
                <td>{decimal(@result.profile.follows_per_khw, 1)}</td>
                <td>{decimal(@result.baseline.follows_per_khw, 1)}</td>
              </tr>
            </tbody>
          </table>
          <p class="text-muted border-t border-base-300 px-4 py-2 text-xs">
            {gettext("%{judged} of %{readings} viewer readings had chat coverage.",
              judged: @result.profile.judged,
              readings: @result.profile.readings
            )}
          </p>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:anomalies}>
      <div id="anomalies-page" phx-hook="Format" class="space-y-4">
        <.page_header title={gettext("Anomalies")} icon="hero-exclamation-triangle">
          <:subtitle>
            {gettext(
              "Streams whose viewers, chat or follows don't behave like the channel's usual ones."
            )}
          </:subtitle>
          <:actions>
            <.live_component
              :if={@channels != []}
              module={KickTrackerWeb.Admin.ChannelPicker}
              id="anomalies-channel"
              channels={@channels}
              selected={@channel}
            />
          </:actions>
        </.page_header>

        <.review_note />

        <.panel :if={@channels == []}>
          <.empty_state icon="hero-tv" title={gettext("No channels yet.")} />
        </.panel>

        <.panel :if={@channel} title={gettext("Streams")} icon="hero-play-circle" flush>
          <div class="overflow-x-auto">
            <table id="anomaly-streams" class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Started")}</th><th>{gettext("Airtime")}</th><th>
                    {gettext("Avg viewers")}
                  </th><th>{gettext("Chatters / min per 100 viewers")}</th><th>{gettext("Usual")}</th><th>
                    {gettext("Findings")}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- @results} id={"stream-#{r.stream.id}"}>
                  <td class="whitespace-nowrap">
                    <.link
                      navigate={~p"/admin/anomalies/#{r.stream.id}"}
                      class="font-medium hover:underline"
                    >
                      <.time at={r.stream.started_at} />
                    </.link>
                    <.status_pill :if={r.stream.excluded?}>{gettext("excluded")}</.status_pill>
                    <span :if={is_nil(r.stream.ended_at)} class="live-pill">{gettext("live")}</span>
                  </td>
                  <td><.duration seconds={r.stream.airtime_s} /></td>
                  <td><.num value={r.stream.avg_viewers} /></td>
                  <td>{per_hundred(r.profile.engagement)}</td>
                  <td>{per_hundred(r.baseline.engagement)}</td>
                  <td>
                    <span :if={r.findings == []} class="text-muted">–</span>
                    <div class="flex flex-wrap gap-1">
                      <.status_pill
                        :for={kind <- r.findings |> Enum.map(& &1.kind) |> Enum.uniq()}
                        tone={:warn}
                      >
                        {label(kind)}
                      </.status_pill>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.empty_state
            :if={@results == []}
            icon="hero-play-circle"
            title={gettext("No streams yet.")}
          />
        </.panel>
      </div>
    </Layouts.admin>
    """
  end

  defp review_note(assigns) do
    ~H"""
    <p class="inset-well flex items-start gap-2 p-3 text-sm">
      <.icon name="hero-information-circle" class="text-muted mt-0.5 size-4 shrink-0" />
      {gettext(
        "Signs for review, not proof: a front-page placement, a followers-only chat or a watch party can look the same. A stream is compared with the channel's own earlier streams, and only where we were collecting. Admin only; nothing here is public."
      )}
    </p>
    """
  end

  @doc "A finding kind's name, as the page and the chart show it."
  def label(:unexplained_jump), do: gettext("Jump without chat")
  def label(:unexplained_drop), do: gettext("Drop without chat")
  def label(:flat_plateau), do: gettext("Flat viewer count")
  def label(:cold_start), do: gettext("Full audience at the start")
  def label(:low_engagement), do: gettext("Little chat for the viewers")
  def label(:low_follows), do: gettext("Few follows for the hours watched")

  defp level_tone(:none), do: :ok
  defp level_tone(:some), do: :warn
  defp level_tone(:several), do: :error

  defp level_label(:none), do: gettext("nothing found")
  defp level_label(:some), do: gettext("one kind of finding")
  defp level_label(:several), do: gettext("several kinds of findings")

  defp describe(%{kind: :unexplained_jump, facts: f}) do
    gettext(
      "Viewers went from %{before} to %{after} while chatters per minute went from %{cb} to %{ca}. No incoming host was seen near it.",
      before: int(f.viewers_before),
      after: int(f.viewers_after),
      cb: decimal(f.chatters_before, 1),
      ca: decimal(f.chatters_after, 1)
    )
  end

  defp describe(%{kind: :unexplained_drop, facts: f}) do
    gettext(
      "Viewers went from %{before} to %{after} while chatters per minute went from %{cb} to %{ca}. No outgoing host was seen near it.",
      before: int(f.viewers_before),
      after: int(f.viewers_after),
      cb: decimal(f.chatters_before, 1),
      ca: decimal(f.chatters_after, 1)
    )
  end

  defp describe(%{kind: :flat_plateau, facts: f}) do
    gettext(
      "About %{level} viewers, changing by a typical %{noise} between readings (this channel usually: %{usual}); %{unchanged} of readings repeated the one before exactly.",
      level: int(f.level),
      noise: pct(f.noise, 2),
      usual: pct(f.usual_noise, 2),
      unchanged: pct(f.unchanged, 0)
    )
  end

  defp describe(%{kind: :cold_start, facts: f}) do
    gettext(
      "The first readings were %{first} viewers, %{share} of the %{settled} the stream settled at after its first 15 minutes (this channel usually: %{usual}), with no incoming host.",
      first: int(f.first_viewers),
      share: pct(f.share, 0),
      settled: int(f.settled_viewers),
      usual: pct(f.usual_share, 0)
    )
  end

  defp describe(%{kind: :low_engagement, facts: f}) do
    gettext(
      "%{e} chatters per minute per 100 viewers, against %{usual} on the channel's %{n} earlier streams (median).",
      e: per_hundred(f.engagement),
      usual: per_hundred(f.usual),
      n: f.streams
    )
  end

  defp describe(%{kind: :low_follows, facts: f}) do
    gettext(
      "%{rate} follows per 1 000 hours watched (%{follows} follows over %{hours} hours), against %{usual} on the channel's %{n} earlier streams (median).",
      rate: decimal(f.rate, 1),
      follows: f.follows,
      hours: int(f.hours_watched),
      usual: decimal(f.usual, 1),
      n: f.streams
    )
  end

  defp chart_labels do
    %{
      viewers: gettext("Viewers"),
      messages: gettext("Messages / min"),
      chatters: gettext("Active chatters"),
      flagged: gettext("flagged reading, not counted as a peak"),
      kinds:
        Map.merge(event_labels(), %{
          "hosted_by" => gettext("Hosted by"),
          "hosting" => gettext("Hosting")
        }),
      event: event_label(nil),
      title: gettext("Title"),
      category: gettext("Category")
    }
  end

  # Unknown stays unknown (AGENTS.md §7): "–", never 0.
  defp int(nil), do: "–"
  defp int(v), do: v |> round() |> Integer.to_string()

  defp decimal(nil, _places), do: "–"
  defp decimal(v, places), do: :erlang.float_to_binary(v / 1, decimals: places)

  defp per_hundred(nil), do: "–"
  defp per_hundred(v), do: decimal(v * 100, 1)

  defp pct(nil, _places), do: "–"
  defp pct(v, places), do: decimal(v * 100, places) <> "%"
end
