defmodule KickTrackerWeb.Admin.AnomaliesLive do
  @moduledoc """
  Audience anomalies (project.md §19.4), admin only: every finding of
  `Metrics.Anomalies` across the channels' latest streams, most recent
  first, each leading to its stream; for one stream, the findings with
  their figures, the stream's chart with them shaded, and its figures
  against the channel's usual ones.

  Signs for review, never a verdict: nothing here reaches the public site.

  While a stream shown (or, on the list, any channel's latest stream) is
  live, the page is read again every minute (the findings, and the
  chart's data), so it follows the stream as it goes; once it has ended
  the page stops.
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

  def handle_params(_params, _uri, socket) do
    %{findings: findings, live?: live?} = Anomalies.recent(Channels.list_all())

    {:noreply,
     socket
     |> assign(findings: findings)
     |> schedule(live?)}
  end

  # Read again in a minute while a stream shown is live: its findings move
  # as it goes. One timer at a time, whatever the page was patched to.
  defp schedule(socket, live?) do
    if ref = socket.assigns[:refresh_ref], do: Process.cancel_timer(ref)
    ref = if live? and connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    assign(socket, refresh_ref: ref)
  end

  @impl true
  def handle_info(:refresh, %{assigns: %{live_action: :show}} = socket) do
    params = %{"id" => to_string(socket.assigns.stream.id)}
    handle_params(params, nil, assign(socket, refresh_ref: nil))
  end

  def handle_info(:refresh, socket),
    do: handle_params(%{}, nil, assign(socket, refresh_ref: nil))

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:anomalies}>
      <div id="anomaly-page" phx-hook="Format" class="space-y-6">
        <.link
          navigate={~p"/admin/anomalies"}
          class="text-muted inline-flex items-center gap-1 text-sm hover:text-base-content"
        >
          <.icon name="hero-arrow-left" class="size-4" />{gettext("All anomalies")}
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
              "Moments where a stream's viewers, chat or follows didn't behave like the channel's usual ones, most recent first."
            )}
          </:subtitle>
        </.page_header>

        <.review_note />

        <.panel title={gettext("Findings")} icon="hero-magnifying-glass" flush>
          <div class="overflow-x-auto">
            <table id="anomalies" class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("When")}</th><th>{gettext("Channel")}</th><th>
                    {gettext("Finding")}
                  </th><th>{gettext("What was seen")}</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={r <- @findings}
                  id={"finding-#{r.stream.id}-#{r.finding.kind}-#{DateTime.to_unix(r.finding.from)}"}
                  class="hover:bg-base-200 cursor-pointer"
                  phx-click={JS.navigate(~p"/admin/anomalies/#{r.stream.id}")}
                >
                  <td class="whitespace-nowrap">
                    <.time at={r.finding.from} /> – <.time at={r.finding.to} fmt="time" />
                  </td>
                  <td class="whitespace-nowrap">
                    <.link
                      navigate={~p"/admin/anomalies/#{r.stream.id}"}
                      class="font-medium hover:underline"
                    >
                      {r.channel.slug}
                    </.link>
                    <span :if={is_nil(r.stream.ended_at)} class="live-pill">{gettext("live")}</span>
                    <.status_pill :if={r.stream.excluded?}>{gettext("excluded")}</.status_pill>
                    <div class="text-muted text-xs">
                      {gettext("stream of")} <.time at={r.stream.started_at} />
                    </div>
                  </td>
                  <td class="whitespace-nowrap">
                    <.status_pill tone={:warn}>{label(r.finding.kind)}</.status_pill>
                  </td>
                  <td class="min-w-80 text-sm">{describe(r.finding)}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <.empty_state
            :if={@findings == []}
            icon="hero-check-circle"
            title={gettext("Nothing stood out in the channels' latest streams.")}
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
      kinds: event_labels(),
      hosts: host_labels(),
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
