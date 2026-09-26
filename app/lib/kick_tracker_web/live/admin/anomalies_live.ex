defmodule KickTrackerWeb.Admin.AnomaliesLive do
  @moduledoc """
  Audience anomalies (project.md §19.4), admin only: for one channel, its
  latest streams with what `Metrics.Anomalies` found in each; for one
  stream, the findings with their figures, the stream's chart with them
  shaded, and its figures against the channel's usual ones.

  Signs for review, never a verdict: nothing here reaches the public site.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{Anomalies, Channels, Reports}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Anomalies"))}

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {id, ""} <- Integer.parse(params["id"] || ""),
         %{} = stream <- Reports.stream(id),
         channel = Channels.get!(stream.channel_id),
         %{} = result <- Anomalies.stream(channel, id) do
      {:noreply, assign(socket, channel: channel, stream: stream, result: result)}
    else
      _ -> raise KickTrackerWeb.NotFoundError, "no such stream"
    end
  end

  def handle_params(params, _uri, socket) do
    channels = Channels.list_all()

    channel =
      Enum.find(channels, &(to_string(&1.id) == params["channel"])) || List.first(channels)

    {:noreply,
     assign(socket,
       channels: channels,
       channel: channel,
       results: if(channel, do: Anomalies.channel_streams(channel), else: [])
     )}
  end

  @impl true
  def handle_event("channel", %{"channel" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/admin/anomalies?channel=#{id}")}

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:anomalies}>
      <div id="anomaly-page" phx-hook="Format" class="space-y-6">
        <.header>
          {@channel.slug} · <.time at={@stream.started_at} />
          <:subtitle>
            <.link navigate={~p"/admin/anomalies?channel=#{@channel.id}"} class="link">
              {gettext("All streams of this channel")}
            </.link>
            · {level_label(@result.level)}
          </:subtitle>
        </.header>

        <.review_note />

        <.chart
          id="anomaly-chart"
          kind="stream"
          src={~p"/admin/anomalies/#{@stream.id}/chart"}
          opts={%{labels: chart_labels()}}
          class="h-[30rem]"
          title={gettext("Viewers and chat, findings shaded")}
        />

        <section>
          <h2 class="mb-2 font-semibold">{gettext("Findings")}</h2>
          <p :if={@result.findings == []} class="text-sm text-base-content/70">
            {gettext("Nothing stood out in what we observed.")}
          </p>
          <ul id="findings" class="space-y-3">
            <li :for={f <- @result.findings} class="card-surface p-3">
              <div class="flex flex-wrap items-center gap-2 text-sm">
                <span class="badge badge-warning badge-sm">{label(f.kind)}</span>
                <.time at={f.from} /> – <.time at={f.to} fmt="time" />
              </div>
              <p class="mt-1 text-sm">{describe(f)}</p>
            </li>
          </ul>
        </section>

        <section>
          <h2 class="mb-2 font-semibold">{gettext("This stream against the channel's usual")}</h2>
          <table id="profile" class="table table-sm w-auto">
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
          <p class="mt-2 text-xs text-base-content/70">
            {gettext("%{judged} of %{readings} viewer readings had chat coverage.",
              judged: @result.profile.judged,
              readings: @result.profile.readings
            )}
          </p>
        </section>
      </div>
    </Layouts.admin>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:anomalies}>
      <div id="anomalies-page" phx-hook="Format" class="space-y-4">
        <.header>
          {gettext("Anomalies")}
          <:subtitle>
            {gettext(
              "Streams whose viewers, chat or follows don't behave like the channel's usual ones."
            )}
          </:subtitle>
        </.header>

        <.review_note />

        <form :if={@channels != []} id="channel-form" phx-change="channel">
          <label class="flex items-center gap-2 text-sm">
            {gettext("Channel")}
            <select name="channel" class="select select-sm w-64">
              <option
                :for={c <- @channels}
                value={c.id}
                selected={@channel && c.id == @channel.id}
              >
                {c.slug}
              </option>
            </select>
          </label>
        </form>

        <p :if={@channels == []} class="text-sm text-base-content/70">
          {gettext("No channels yet.")}
        </p>

        <table :if={@channel} id="anomaly-streams" class="table table-sm">
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
                <.link navigate={~p"/admin/anomalies/#{r.stream.id}"} class="link">
                  <.time at={r.stream.started_at} />
                </.link>
                <span :if={r.stream.excluded?} class="badge badge-ghost badge-xs">
                  {gettext("excluded")}
                </span>
                <span :if={is_nil(r.stream.ended_at)} class="badge badge-ghost badge-xs">
                  {gettext("live")}
                </span>
              </td>
              <td><.duration seconds={r.stream.airtime_s} /></td>
              <td><.num value={r.stream.avg_viewers} /></td>
              <td>{per_hundred(r.profile.engagement)}</td>
              <td>{per_hundred(r.baseline.engagement)}</td>
              <td>
                <span :if={r.findings == []} class="text-base-content/50">–</span>
                <span
                  :for={kind <- r.findings |> Enum.map(& &1.kind) |> Enum.uniq()}
                  class="badge badge-warning badge-sm me-1"
                >
                  {label(kind)}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@channel && @results == []} class="text-sm text-base-content/70">
          {gettext("No streams yet.")}
        </p>
      </div>
    </Layouts.admin>
    """
  end

  defp review_note(assigns) do
    ~H"""
    <p class="rounded-box border border-base-300 bg-base-200 p-3 text-sm">
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
