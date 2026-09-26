defmodule KickTrackerWeb.Admin.HealthLive do
  @moduledoc """
  The collection's health (project.md §13.8): per channel, whether each
  source works and how much of the last day, week and month, and of the
  time since it was added, it covered;
  system-wide, the queue, the receivers and the jobs. Refreshes every 30s.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.Health

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
    {:ok, socket |> assign(page_title: gettext("Health"), q: "", show: "all") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    socket
    |> assign(
      now: DateTime.utc_now(),
      rows: Health.channels(),
      long_coverage: Health.long_coverage(),
      ingress: Health.ingress(),
      jobs: Health.jobs(),
      alerts: KickTracker.Alerts.open_alerts(),
      collectors: Health.collectors(),
      terms: Health.terms(),
      payload_issues: Health.payload_issues(DateTime.add(DateTime.utc_now(), -7, :day))
    )
    |> assign_async([:queues, :subscriptions], fn ->
      {:ok, %{queues: Health.queues(), subscriptions: Health.subscriptions()}}
    end)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, q: q)}

  def handle_event("show", %{"show" => show}, socket) when show in ~w(all problems live),
    do: {:noreply, assign(socket, show: show)}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        problems: Enum.count(assigns.rows, &problem?(&1, assigns)),
        live: Enum.count(assigns.rows, & &1.live_since),
        shown: shown_rows(assigns)
      )

    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:health}>
      <.page_header title={gettext("Health")} icon="hero-heart">
        <:subtitle>
          {gettext("Collection at a glance. Updated %{at} UTC, every 30 seconds.",
            at: Calendar.strftime(@now, "%H:%M:%S")
          )}
        </:subtitle>
      </.page_header>

      <div id="health-summary" class="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat_tile
          icon="hero-cpu-chip"
          label={gettext("Collection")}
          tone={if collecting?(@collectors, @now), do: :ok, else: :error}
        >
          {if collecting?(@collectors, @now), do: gettext("running"), else: gettext("stopped")}
          <:hint>
            {ngettext("1 collector heard", "%{count} collectors heard", length(@collectors))}
          </:hint>
        </.stat_tile>
        <.stat_tile
          icon="hero-bell-alert"
          label={gettext("Open alerts")}
          tone={if @alerts == [], do: :ok, else: :error}
        >
          {length(@alerts)}
        </.stat_tile>
        <.stat_tile
          icon="hero-tv"
          label={gettext("Channels")}
          tone={if @problems == 0, do: :ok, else: :warn}
        >
          {length(@rows)}
          <:hint>
            {ngettext("1 with a problem", "%{count} with a problem", @problems)} · {ngettext(
              "1 live",
              "%{count} live",
              @live
            )}
          </:hint>
        </.stat_tile>
        <.stat_tile
          icon="hero-inbox-arrow-down"
          label={gettext("Events waiting")}
          tone={if @ingress.unprocessed == 0, do: :ok, else: :warn}
        >
          {@ingress.unprocessed}
          <:hint :if={@ingress.oldest_unprocessed}>
            {gettext("oldest %{ago}", ago: ago(@ingress.oldest_unprocessed, @now))}
          </:hint>
        </.stat_tile>
      </div>

      <.panel
        :if={@alerts != []}
        id="open-alerts"
        title={gettext("Open alerts")}
        icon="hero-bell-alert"
        class="mb-6 border-error/50"
      >
        <:subtitle>{ngettext("1 alert", "%{count} alerts", length(@alerts))}</:subtitle>
        <ul class="scroll-panel max-h-64 space-y-2 overflow-y-auto pe-1 text-sm">
          <li :for={a <- @alerts} class="flex items-start gap-2">
            <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0 text-error" />
            <span class="flex-1">{a.message}</span>
            <span class="text-muted shrink-0 text-xs">{gettext("since")} {ago(a.first_at, @now)}</span>
          </li>
        </ul>
      </.panel>

      <.panel
        id="collector-health"
        title={gettext("Collectors")}
        icon="hero-cpu-chip"
        class="mb-6"
        flush
      >
        <:actions>
          <span :if={KickTracker.build()} id="web-build" class="text-muted text-xs">
            {gettext("This page is served by build")}
            <span class="font-mono" title={KickTracker.build()}>{short_build(KickTracker.build())}</span>.
          </span>
        </:actions>
        <.empty_state
          :if={@collectors == []}
          icon="hero-cpu-chip"
          title={gettext("No collector has reported in the last day.")}
        />
        <div :if={@collectors != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Collector")}</th>
                <th>{gettext("Role")}</th>
                <th>{gettext("Build")}</th>
                <th>{gettext("Last heard")}</th>
                <th class="text-end">{gettext("Writes waiting")}</th>
                <th class="text-end">{gettext("Set aside")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @collectors} id={"collector-#{c.id}"}>
                <td class="font-mono text-sm">{c.id}</td>
                <td>
                  <.status_pill tone={collector_tone(c, @now)}>
                    {collector_role(c, @now)}
                  </.status_pill>
                </td>
                <td class="font-mono text-sm" title={c[:build]}>
                  {short_build(c[:build])}
                  <span
                    :if={c[:build] && KickTracker.build() && c[:build] != KickTracker.build()}
                    class="text-muted text-xs"
                    title={gettext("Not the build this page runs on")}
                  >{gettext("(other build)")}</span>
                </td>
                <td class="text-sm">{ago(c.heartbeat_at, @now)}</td>
                <td class="text-end tabular-nums">
                  {c.journal_depth}
                  <span :if={c.journal_oldest_at} class="text-muted text-xs">({gettext("oldest")} {ago(
                    c.journal_oldest_at,
                    @now
                  )})</span>
                </td>
                <td class={["text-end tabular-nums", c.journal_buried > 0 && "font-medium text-error"]}>
                  {c.journal_buried}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div
          :if={quarantined(@collectors) != [] or @terms != []}
          class="space-y-3 border-t border-base-300 p-4"
        >
          <div
            :for={{c, q} <- quarantined(@collectors)}
            id={"quarantined-#{c.id}-#{q.channel_id}"}
            class="alert alert-warning text-sm"
          >
            <.icon name="hero-exclamation-triangle-micro" class="size-4" />
            <span>
              {gettext(
                "%{channel} kept crashing on %{collector} (%{failures} times in a row) and waits to be restarted.",
                channel: channel_name(@rows, q.channel_id),
                collector: c.id,
                failures: q.failures
              )}
              <span :if={q.since}>{gettext("Since")} <.time at={q.since} />.</span>
            </span>
          </div>
          <details :if={@terms != []} class="text-sm">
            <summary class="text-muted cursor-pointer">{gettext("Recent handoffs")}</summary>
            <ol class="mt-2 space-y-1">
              <li :for={t <- @terms} class="flex flex-wrap items-center gap-x-2">
                <span class="font-mono">{t.holder}</span>
                <span class="text-muted">{gettext("from")} <.time at={t.started_at} /></span>
                <span :if={t.ended_at} class="text-muted">
                  {gettext("to")} <.time at={t.ended_at} /> ({t.reason})
                </span>
                <.status_pill :if={!t.ended_at} tone={:ok}>{gettext("now")}</.status_pill>
              </li>
            </ol>
          </details>
        </div>
      </.panel>

      <.panel id="channels-panel" title={gettext("Channels")} icon="hero-tv" class="mb-6" flush>
        <:actions>
          <nav class="segmented" aria-label={gettext("Show")}>
            <button
              :for={
                {key, label} <- [
                  {"all", gettext("All")},
                  {"problems", gettext("Problems") <> " · #{@problems}"},
                  {"live", gettext("Live") <> " · #{@live}"}
                ]
              }
              id={"health-show-#{key}"}
              type="button"
              phx-click="show"
              phx-value-show={key}
              class={["segmented-item", @show == key && "is-active"]}
            >
              {label}
            </button>
          </nav>
          <.search_field
            id="health-search"
            event="search"
            value={@q}
            placeholder={gettext("Search channels")}
          />
        </:actions>
        <div class="scroll-panel max-h-[70vh] overflow-auto">
          <table id="channel-health" class="table table-sm table-pin-rows">
            <thead>
              <tr>
                <th>{gettext("Channel")}</th>
                <th>{gettext("Viewer poll")}</th>
                <th>{gettext("Chat")}</th>
                <th>{gettext("Webhooks")}</th>
                <th>{gettext("Last event")}</th>
                <th>{gettext("Followers read")}</th>
                <th title={coverage_help()}>{gettext("Poll coverage")}</th>
                <th title={coverage_help()}>{gettext("Chat coverage")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={r <- @shown}
                id={"health-#{r.channel.id}"}
                class={!r.channel.active && "opacity-60"}
              >
                <td>
                  <div class="flex items-center gap-2">
                    <.avatar name={r.channel.slug} channel_id={r.channel.id} class="size-7 text-xs" />
                    <div class="min-w-0">
                      <p class="truncate font-medium">{r.channel.slug}</p>
                      <p class="flex flex-wrap gap-1">
                        <span :if={r.live_since} class="live-pill">{gettext("live")} {ago(
                          r.live_since,
                          @now
                        )}</span>
                        <span :if={!r.channel.active} class="text-muted text-xs">{gettext("paused")}</span>
                      </p>
                    </div>
                  </div>
                </td>
                <td><.source_state s={r.poll} now={@now} /></td>
                <td><.source_state s={r.chat} now={@now} /></td>
                <td>
                  <.async_result :let={subs} assign={@subscriptions}>
                    <:loading><span class="text-muted">…</span></:loading>
                    <:failed><span class="text-muted">?</span></:failed>
                    <%= case subs do %>
                      <% {:ok, s} -> %>
                        <% n = Map.get(s.by_user, r.channel.kick_user_id, 0) %>
                        <.status_pill tone={if r.channel.active and n < s.want, do: :error, else: :ok}>
                          {n}/{s.want}
                        </.status_pill>
                      <% {:error, _} -> %>
                        <span class="text-muted">?</span>
                    <% end %>
                  </.async_result>
                </td>
                <td class="text-muted whitespace-nowrap text-xs">
                  {if r.last_event, do: ago(r.last_event, @now), else: "–"}
                </td>
                <td class="text-muted whitespace-nowrap text-xs">
                  {if r.last_follower_reading, do: ago(r.last_follower_reading, @now), else: "–"}
                </td>
                <% long = Map.get(@long_coverage, r.channel.id, %{}) %>
                <td>
                  <.coverage values={[
                    {"24h", r.coverage.api_24h},
                    {"7d", r.coverage.api_7d},
                    {"30d", long[:api_30d]},
                    {"all", long[:api_all]}
                  ]} />
                </td>
                <td>
                  <.coverage values={[
                    {"24h", r.coverage.chat_24h},
                    {"7d", r.coverage.chat_7d},
                    {"30d", long[:chat_30d]},
                    {"all", long[:chat_all]}
                  ]} />
                </td>
              </tr>
            </tbody>
          </table>
          <.empty_state :if={@rows == []} icon="hero-tv" title={gettext("No channels yet.")}>
            <.link navigate={~p"/admin/channels"} class="link">{gettext("Add one.")}</.link>
          </.empty_state>
          <.empty_state
            :if={@rows != [] and @shown == []}
            icon="hero-check-circle"
            title={
              if @show == "problems",
                do: gettext("No channel has a problem."),
                else: gettext("No channel matches.")
            }
          />
        </div>
      </.panel>

      <.panel
        :if={@payload_issues != []}
        id="payload-issues"
        title={gettext("Webhooks with an unexpected shape (7 days)")}
        icon="hero-exclamation-triangle"
        class="mb-6 border-warning/50"
      >
        <ul class="space-y-1 text-sm">
          <li :for={i <- @payload_issues}>
            <span class="font-mono text-xs">{i.event_type} v{i.event_version}</span>: {i.problem}
            <span class="text-muted text-xs">({i.count}×, {gettext("last")} {ago(i.last_seen_at, @now)}, {gettext(
              "e.g."
            )} {i.example_message_id})</span>
          </li>
        </ul>
      </.panel>

      <div class="grid gap-6 lg:grid-cols-3">
        <.panel id="queue-health" title={gettext("Queue")} icon="hero-queue-list">
          <.async_result :let={queues} assign={@queues}>
            <:loading>
              <p class="text-muted text-sm">…</p>
            </:loading>
            <:failed>
              <p class="text-sm text-error">{gettext("Could not read")}</p>
            </:failed>
            <%= case queues do %>
              <% {:ok, qs} -> %>
                <dl class="kv-list">
                  <%= for q <- qs do %>
                    <dt>{q.name}</dt>
                    <dd class={[
                      (String.ends_with?(q.name, ".dead") and q.messages > 0) &&
                        "font-medium text-error"
                    ]}>
                      {q.messages}
                      <span class="text-muted text-xs">
                        ({q.unacked} {gettext("unacked")}, {q.consumers} {gettext("consumers")})
                      </span>
                    </dd>
                  <% end %>
                </dl>
              <% :not_configured -> %>
                <p class="text-muted text-sm">{gettext("RABBITMQ_MANAGEMENT_URL is not set.")}</p>
              <% {:error, reason} -> %>
                <p class="text-sm text-error">
                  {gettext("RabbitMQ didn't answer: %{r}", r: inspect(reason))}
                </p>
            <% end %>
          </.async_result>
          <dl class="kv-list mt-4 border-t border-base-300 pt-3">
            <dt>{gettext("Consumer lag (p95, last hour)")}</dt>
            <dd>{if @ingress.lag_p95_s, do: "#{Float.round(@ingress.lag_p95_s, 1)} s", else: "–"}</dd>
            <dt>{gettext("Events waiting for their channel")}</dt>
            <dd>
              {@ingress.unprocessed}
              <span :if={@ingress.oldest_unprocessed} class="text-muted text-xs">({gettext("oldest")} {ago(
                @ingress.oldest_unprocessed,
                @now
              )})</span>
            </dd>
          </dl>
        </.panel>

        <.panel id="receiver-health" title={gettext("Receivers")} icon="hero-signal">
          <p :if={@ingress.receivers == []} class="text-muted text-sm">
            {gettext("No deliveries in the last 7 days.")}
          </p>
          <dl class="kv-list">
            <%= for r <- @ingress.receivers do %>
              <dt>{r.name}</dt>
              <dd>{ago(r.last_at, @now)} · {r.last_hour}/h</dd>
            <% end %>
          </dl>
        </.panel>

        <.panel id="job-health" title={gettext("Jobs")} icon="hero-cog-8-tooth">
          <:actions>
            <a href={~p"/admin/dashboard"} class="btn btn-ghost btn-xs gap-1">
              {gettext("LiveDashboard")}<.icon name="hero-arrow-up-right" class="size-3" />
            </a>
          </:actions>
          <dl class="kv-list">
            <%= for c <- @jobs.counts do %>
              <dt>{c.queue} · {c.state}</dt>
              <dd class={[c.state in ["retryable", "discarded"] && "text-error"]}>{c.count}</dd>
            <% end %>
          </dl>
          <ul :if={@jobs.failures != []} class="mt-3 space-y-1 border-t border-base-300 pt-3 text-xs">
            <li :for={f <- @jobs.failures} class="break-words">
              <span class="font-medium">{f.worker |> String.split(".") |> List.last()}</span>
              {f.state} {ago(f.at, @now)}: <span class="text-muted">{f.error}</span>
            </li>
          </ul>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end

  attr :values, :list, required: true

  # A source's coverage over four windows as small meters, the first
  # (24h) also as a figure; each window's figure on hover.
  defp coverage(assigns) do
    ~H"""
    <div
      class="flex items-center gap-2"
      title={Enum.map_join(@values, " · ", fn {w, v} -> "#{w} #{pct(v)}" end)}
    >
      <span class="w-12 text-end text-sm tabular-nums">{pct(elem(hd(@values), 1))}</span>
      <span class="flex items-end gap-0.5" aria-hidden="true">
        <span
          :for={{_w, v} <- @values}
          class={["coverage-bar", coverage_tone(v)]}
          style={"--level: #{if v, do: Float.round(v * 100, 1), else: 0}%"}
        ></span>
      </span>
    </div>
    """
  end

  defp coverage_tone(nil), do: "tone-neutral"
  defp coverage_tone(v) when v >= 0.98, do: "tone-ok"
  defp coverage_tone(v) when v >= 0.9, do: "tone-warn"
  defp coverage_tone(_), do: "tone-error"

  defp coverage_help,
    do:
      gettext(
        "Share of 24h, 7 days, 30 days and all time the source recorded, counted from when the channel was added"
      )

  # Something to look at: an active channel whose poll or chat isn't
  # working, whose webhook subscriptions aren't all there, or whose poll
  # covered less than 90% of the last day.
  defp problem?(r, assigns) do
    subs_short? =
      case assigns.subscriptions do
        %{ok?: true, result: {:ok, s}} -> Map.get(s.by_user, r.channel.kick_user_id, 0) < s.want
        _ -> false
      end

    r.channel.active and
      (r.poll.state in [:failing, :stale] or r.chat.state in [:failing, :stale] or subs_short? or
         (is_number(r.coverage.api_24h) and r.coverage.api_24h < 0.9))
  end

  defp shown_rows(assigns) do
    q = String.downcase(String.trim(assigns.q))

    Enum.filter(assigns.rows, fn r ->
      (q == "" or String.contains?(String.downcase(r.channel.slug), q)) and
        case assigns.show do
          "problems" -> problem?(r, assigns)
          "live" -> r.live_since != nil
          _ -> true
        end
    end)
  end

  defp collecting?(collectors, now),
    do:
      Enum.any?(collectors, &(&1.state == "leader" and DateTime.diff(now, &1.heartbeat_at) <= 90))

  attr :s, :map, required: true
  attr :now, DateTime, required: true

  defp source_state(assigns) do
    ~H"""
    <div class="flex flex-col items-start gap-0.5">
      <.status_pill tone={state_tone(@s.state)}>{label(@s.state)}</.status_pill>
      <span :if={@s.at} class="text-muted whitespace-nowrap text-xs">{ago(@s.at, @now)}</span>
    </div>
    """
  end

  defp state_tone(:ok), do: :ok
  defp state_tone(:never), do: :neutral
  defp state_tone(_), do: :error

  defp label(:ok), do: gettext("ok")
  defp label(:failing), do: gettext("failing")
  defp label(:stale), do: gettext("stale")
  defp label(:never), do: gettext("never")

  defp pct(nil), do: "–"
  defp pct(f), do: "#{:erlang.float_to_binary(f * 100, decimals: 1)}%"

  defp ago(at, now) do
    s = max(DateTime.diff(now, at), 0)

    cond do
      s < 90 -> gettext("%{n}s ago", n: s)
      s < 5400 -> gettext("%{n}m ago", n: div(s, 60))
      s < 172_800 -> gettext("%{n}h ago", n: div(s, 3600))
      true -> gettext("%{n}d ago", n: div(s, 86_400))
    end
  end

  # A commit, shortened as git does; unknown for images built before
  # BUILD_SHA was set.
  defp short_build(nil), do: "–"
  defp short_build(sha), do: String.slice(sha, 0, 7)

  defp quarantined(collectors),
    do: for(c <- collectors, q <- c[:quarantined] || [], do: {c, q})

  defp channel_name(rows, id) do
    case Enum.find(rows, &(&1.channel.id == id)) do
      nil -> gettext("channel %{id}", id: id)
      row -> row.channel.slug
    end
  end

  # A collector unheard of for 90s is down, whatever its row says (the
  # shadow, read every 5 minutes, after 15).
  defp collector_role(c, now) do
    if DateTime.diff(now, c.heartbeat_at) > if(c.state == "shadow", do: 900, else: 90),
      do: gettext("down"),
      else: role_label(c.state)
  end

  defp role_label("leader"), do: gettext("collecting")
  defp role_label("standby"), do: gettext("standing by")
  defp role_label("stopped"), do: gettext("stopped")
  defp role_label("shadow"), do: gettext("shadow, on another machine")
  defp role_label(other), do: other

  defp collector_tone(c, now) do
    cond do
      DateTime.diff(now, c.heartbeat_at) > if(c.state == "shadow", do: 900, else: 90) -> :error
      c.state == "leader" -> :ok
      c.state == "standby" -> :info
      true -> :neutral
    end
  end
end
