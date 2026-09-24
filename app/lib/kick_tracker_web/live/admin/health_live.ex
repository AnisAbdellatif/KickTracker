defmodule KickTrackerWeb.Admin.HealthLive do
  @moduledoc """
  The collection's health (project.md §13.8): per channel, whether each
  source works and how much of the last day and week it covered;
  system-wide, the queue, the receivers and the jobs. Refreshes every 30s.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.Health

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)
    {:ok, socket |> assign(page_title: gettext("Health")) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    socket
    |> assign(
      now: DateTime.utc_now(),
      rows: Health.channels(),
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
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:health}>
      <.header>
        {gettext("Health")}
        <:subtitle>{gettext("Updated %{at} UTC", at: Calendar.strftime(@now, "%H:%M:%S"))}</:subtitle>
      </.header>

      <section :if={@alerts != []} id="open-alerts" class="mb-6 rounded-box border border-error p-3">
        <h2 class="font-semibold text-error">{gettext("Open alerts")}</h2>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={a <- @alerts}>
            {a.message}
            <span class="text-xs opacity-60">({gettext("since")} {ago(a.first_at, @now)})</span>
          </li>
        </ul>
      </section>

      <section id="collector-health" class="mb-6 card-surface p-4">
        <h2 class="font-semibold">{gettext("Collectors")}</h2>
        <p :if={@collectors == []} class="mt-2 text-sm opacity-60">
          {gettext("No collector has reported in the last day.")}
        </p>
        <table :if={@collectors != []} class="table table-xs mt-2">
          <thead>
            <tr>
              <th>{gettext("Collector")}</th><th>{gettext("Role")}</th><th>
                {gettext("Last heard")}
              </th><th>{gettext("Writes waiting")}</th><th>{gettext("Set aside")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @collectors} id={"collector-#{c.id}"}>
              <td class="font-mono">{c.id}</td>
              <td>
                <span class={[
                  "badge badge-xs",
                  collector_badge(c, @now)
                ]}>{collector_role(c, @now)}</span>
              </td>
              <td>{ago(c.heartbeat_at, @now)}</td>
              <td class="tabular-nums">
                {c.journal_depth}
                <span :if={c.journal_oldest_at} class="text-xs opacity-60">({gettext("oldest")} {ago(
                  c.journal_oldest_at,
                  @now
                )})</span>
              </td>
              <td class={["tabular-nums", c.journal_buried > 0 && "text-error font-medium"]}>
                {c.journal_buried}
              </td>
            </tr>
          </tbody>
        </table>
        <div
          :for={{c, q} <- quarantined(@collectors)}
          id={"quarantined-#{c.id}-#{q.channel_id}"}
          class="alert alert-warning mt-3 text-sm"
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
        <details :if={@terms != []} class="mt-3 text-sm">
          <summary class="cursor-pointer opacity-70">{gettext("Recent handoffs")}</summary>
          <ul class="mt-2 space-y-1">
            <li :for={t <- @terms}>
              <span class="font-mono">{t.holder}</span>
              {gettext("from")} <.time at={t.started_at} />
              <span :if={t.ended_at}>{gettext("to")} <.time at={t.ended_at} /> ({t.reason})</span>
              <span :if={!t.ended_at} class="badge badge-success badge-xs">{gettext("now")}</span>
            </li>
          </ul>
        </details>
      </section>

      <div class="overflow-x-auto">
        <table id="channel-health" class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Channel")}</th>
              <th>{gettext("Live")}</th>
              <th>{gettext("Viewer poll")}</th>
              <th>{gettext("Chat")}</th>
              <th>{gettext("Webhooks")}</th>
              <th>{gettext("Last event")}</th>
              <th>{gettext("Followers read")}</th>
              <th class="text-end">{gettext("Poll 24h / 7d")}</th>
              <th class="text-end">{gettext("Chat 24h / 7d")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={r <- @rows}
              id={"health-#{r.channel.id}"}
              class={!r.channel.active && "opacity-50"}
            >
              <td>
                <span class="font-medium">{r.channel.slug}</span>
                <span :if={!r.channel.active} class="text-xs">({gettext("paused")})</span>
              </td>
              <td>
                <span :if={r.live_since} class="badge badge-error badge-sm">{ago(r.live_since, @now)}</span>
              </td>
              <td><.source_state s={r.poll} now={@now} /></td>
              <td><.source_state s={r.chat} now={@now} /></td>
              <td>
                <.async_result :let={subs} assign={@subscriptions}>
                  <:loading>…</:loading>
                  <:failed>?</:failed>
                  <%= case subs do %>
                    <% {:ok, s} -> %>
                      <% n = Map.get(s.by_user, r.channel.kick_user_id, 0) %>
                      <span class={[r.channel.active && n < s.want && "text-error font-medium"]}>{n}/{s.want}</span>
                    <% {:error, _} -> %>
                      <span class="opacity-60">?</span>
                  <% end %>
                </.async_result>
              </td>
              <td class="text-xs">{if r.last_event, do: ago(r.last_event, @now), else: "–"}</td>
              <td class="text-xs">
                {if r.last_follower_reading, do: ago(r.last_follower_reading, @now), else: "–"}
              </td>
              <td class="text-end tabular-nums">
                {pct(r.coverage.api_24h)} / {pct(r.coverage.api_7d)}
              </td>
              <td class="text-end tabular-nums">
                {pct(r.coverage.chat_24h)} / {pct(r.coverage.chat_7d)}
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@rows == []} class="mt-4 text-sm opacity-70">
          {gettext("No channels yet.")}
          <.link navigate={~p"/admin/channels"} class="link">{gettext("Add one.")}</.link>
        </p>
      </div>

      <section
        :if={@payload_issues != []}
        id="payload-issues"
        class="mt-8 rounded-box border border-warning p-3"
      >
        <h2 class="font-semibold">{gettext("Webhooks with an unexpected shape (7 days)")}</h2>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={i <- @payload_issues}>
            <span class="font-mono text-xs">{i.event_type} v{i.event_version}</span>: {i.problem}
            <span class="text-xs opacity-60">({i.count}×, {gettext("last")} {ago(i.last_seen_at, @now)}, {gettext(
              "e.g."
            )} {i.example_message_id})</span>
          </li>
        </ul>
      </section>

      <div class="mt-10 grid gap-6 lg:grid-cols-3">
        <section id="queue-health" class="card-surface p-4">
          <h2 class="font-semibold">{gettext("Queue")}</h2>
          <.async_result :let={queues} assign={@queues}>
            <:loading>
              <p class="text-sm opacity-60">…</p>
            </:loading>
            <:failed>
              <p class="text-sm text-error">{gettext("Could not read")}</p>
            </:failed>
            <%= case queues do %>
              <% {:ok, qs} -> %>
                <dl class="mt-2 grid grid-cols-[1fr_auto] gap-x-4 gap-y-1 text-sm">
                  <%= for q <- qs do %>
                    <dt>{q.name}</dt>
                    <dd class={[
                      "tabular-nums",
                      (String.ends_with?(q.name, ".dead") and q.messages > 0) &&
                        "text-error font-medium"
                    ]}>
                      {q.messages} ({q.unacked} {gettext("unacked")}, {q.consumers} {gettext(
                        "consumers"
                      )})
                    </dd>
                  <% end %>
                </dl>
              <% :not_configured -> %>
                <p class="mt-2 text-sm opacity-60">
                  {gettext("RABBITMQ_MANAGEMENT_URL is not set.")}
                </p>
              <% {:error, reason} -> %>
                <p class="mt-2 text-sm text-error">
                  {gettext("RabbitMQ didn't answer: %{r}", r: inspect(reason))}
                </p>
            <% end %>
          </.async_result>
          <dl class="mt-4 grid grid-cols-[1fr_auto] gap-x-4 gap-y-1 text-sm">
            <dt>{gettext("Consumer lag (p95, last hour)")}</dt>
            <dd class="tabular-nums">
              {if @ingress.lag_p95_s, do: "#{Float.round(@ingress.lag_p95_s, 1)} s", else: "–"}
            </dd>
            <dt>{gettext("Events waiting for their channel")}</dt>
            <dd class="tabular-nums">
              {@ingress.unprocessed}
              <span :if={@ingress.oldest_unprocessed} class="text-xs opacity-60">({gettext("oldest")} {ago(
                @ingress.oldest_unprocessed,
                @now
              )})</span>
            </dd>
          </dl>
        </section>

        <section id="receiver-health" class="card-surface p-4">
          <h2 class="font-semibold">{gettext("Receivers")}</h2>
          <p :if={@ingress.receivers == []} class="mt-2 text-sm opacity-60">
            {gettext("No deliveries in the last 7 days.")}
          </p>
          <dl class="mt-2 grid grid-cols-[1fr_auto] gap-x-4 gap-y-1 text-sm">
            <%= for r <- @ingress.receivers do %>
              <dt>{r.name}</dt>
              <dd class="tabular-nums">{ago(r.last_at, @now)} · {r.last_hour}/h</dd>
            <% end %>
          </dl>
        </section>

        <section id="job-health" class="card-surface p-4">
          <h2 class="font-semibold">{gettext("Jobs")}</h2>
          <dl class="mt-2 grid grid-cols-[1fr_auto] gap-x-4 gap-y-1 text-sm">
            <%= for c <- @jobs.counts do %>
              <dt>{c.queue} · {c.state}</dt>
              <dd class={["tabular-nums", c.state in ["retryable", "discarded"] && "text-error"]}>
                {c.count}
              </dd>
            <% end %>
          </dl>
          <ul class="mt-3 space-y-1 text-xs">
            <li :for={f <- @jobs.failures} class="break-words">
              <span class="font-medium">{f.worker |> String.split(".") |> List.last()}</span>
              {f.state} {ago(f.at, @now)}: <span class="opacity-70">{f.error}</span>
            </li>
          </ul>
          <a href={~p"/admin/dashboard"} class="link mt-3 inline-block text-sm">{gettext(
            "LiveDashboard"
          )}</a>
        </section>
      </div>
    </Layouts.admin>
    """
  end

  attr :s, :map, required: true
  attr :now, DateTime, required: true

  defp source_state(assigns) do
    ~H"""
    <span class={[
      "text-xs",
      @s.state == :ok && "text-success",
      @s.state in [:failing, :stale] && "text-error font-medium",
      @s.state == :never && "opacity-50"
    ]}>
      {label(@s.state)}<span :if={@s.at}> · {ago(@s.at, @now)}</span>
    </span>
    """
  end

  defp label(:ok), do: gettext("ok")
  defp label(:failing), do: gettext("failing")
  defp label(:stale), do: gettext("stale")
  defp label(:never), do: gettext("never")

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

  defp collector_badge(c, now) do
    cond do
      DateTime.diff(now, c.heartbeat_at) > if(c.state == "shadow", do: 900, else: 90) ->
        "badge-error"

      c.state == "leader" ->
        "badge-success"

      c.state == "standby" ->
        "badge-info"

      true ->
        "badge-ghost"
    end
  end
end
