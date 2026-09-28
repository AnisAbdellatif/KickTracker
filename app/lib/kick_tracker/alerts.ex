defmodule KickTracker.Alerts do
  @moduledoc """
  Alerts (project.md §18.2): every minute the collector takes a snapshot
  of the collection's state, `Alerts.Rules` says what is wrong, and each
  problem is notified once when it starts and once when it is resolved
  (and reminded every 6 hours while it lasts). The `alerts` table keeps
  the history; the health page shows the open ones.
  """

  import Ecto.Query

  alias KickTracker.{DeadLetters, Health, Repo}
  alias KickTracker.Alerts.{Notifier, Rules}

  @remind_s 6 * 3600

  @doc """
  Checks now: opens, reminds and resolves alerts. Returns the open ones.
  Web nodes and the leading collector both check; a transaction lock lets
  one check at a time, and a check that finds another running skips.

  Notifications go out after the commit, so a slow or refusing target
  can't roll back what was recorded (and have it sent again the next
  minute); several of one kind at once go out as one message.
  """
  @spec run(DateTime.t(), (String.t(), Notifier.priority() -> term())) :: [map()]
  def run(now \\ DateTime.utc_now(), notify \\ &Notifier.send/2) do
    {:ok, {changes, open}} =
      Repo.transaction(
        fn ->
          changes =
            if Repo.query!("SELECT pg_try_advisory_xact_lock(4242, 1)").rows == [[true]],
              do: check(now),
              else: []

          {changes, open_alerts()}
        end,
        timeout: 60_000
      )

    for {text, priority} <- messages(changes), do: notify.(text, priority)
    open
  end

  # Records what changed; returns it as `{kind, message}`, in order.
  defp check(now) do
    problems = snapshot(now) |> Rules.evaluate(now) |> Map.new(&{&1.key, &1})

    open =
      Repo.all(
        from a in "alerts",
          where: is_nil(a.resolved_at),
          select: %{id: a.id, key: a.key, notified_at: a.notified_at, message: a.message}
      )

    open_keys = MapSet.new(open, & &1.key)

    changed =
      for a <- open do
        case problems[a.key] do
          nil ->
            Repo.update_all(from(x in "alerts", where: x.id == ^a.id), set: [resolved_at: now])
            {:resolved, a.message}

          p ->
            remind? = a.notified_at == nil or DateTime.diff(now, a.notified_at) > @remind_s

            Repo.update_all(from(x in "alerts", where: x.id == ^a.id),
              set:
                [last_at: now, message: p.message] ++
                  if(remind?, do: [notified_at: now], else: [])
            )

            remind? && {:still, p.message}
        end
      end

    started =
      for {key, p} <- problems, not MapSet.member?(open_keys, key) do
        Repo.insert_all(
          "alerts",
          [%{key: key, message: p.message, first_at: now, last_at: now, notified_at: now}],
          on_conflict: :nothing
        )

        {:new, p.message}
      end

    started ++ Enum.filter(changed, & &1)
  end

  # Up to this many of a kind are sent one by one; more become one message
  # listing the first few. An outage of Kick opens (and later resolves) an
  # alert per channel: one message each would be dozens a minute, and ntfy
  # refuses a burst like that.
  @one_by_one 3
  @listed 10

  defp messages(changes) do
    for kind <- [:new, :still, :resolved],
        of_kind = for({^kind, m} <- changes, do: m),
        of_kind != [],
        message <- combine(kind, of_kind),
        do: message
  end

  defp combine(kind, [_ | _] = messages) when length(messages) <= @one_by_one,
    do: Enum.map(messages, &{prefix(kind) <> &1, priority(kind)})

  defp combine(kind, messages) do
    n = length(messages)
    shown = Enum.take(messages, @listed)
    more = if n > @listed, do: ["…and #{n - @listed} more"], else: []
    lines = Enum.map(shown, &("• " <> String.slice(&1, 0, 150))) ++ more

    [{Enum.join([heading(kind, n) | lines], "\n"), priority(kind)}]
  end

  defp prefix(:new), do: "🔴 "
  defp prefix(:still), do: "🔴 still: "
  defp prefix(:resolved), do: "✅ resolved: "

  defp heading(:new, n), do: "🔴 #{n} new problems:"
  defp heading(:still, n), do: "🔴 still, #{n} problems:"
  defp heading(:resolved, n), do: "✅ #{n} resolved:"

  defp priority(:new), do: :high
  defp priority(:still), do: :default
  defp priority(:resolved), do: :low

  @doc "The open alerts, oldest first."
  @spec open_alerts() :: [map()]
  def open_alerts,
    do:
      Repo.all(
        from a in "alerts",
          where: is_nil(a.resolved_at),
          order_by: a.first_at,
          select: %{key: a.key, message: a.message, first_at: a.first_at, last_at: a.last_at}
      )

  @doc "What the rules look at."
  @spec snapshot(DateTime.t()) :: map()
  def snapshot(now) do
    channels =
      for r <- Health.channels(now) do
        %{
          id: r.channel.id,
          slug: r.channel.slug,
          active: r.channel.active,
          tracked_since: r.channel.tracked_since,
          live_since: r.live_since,
          poll_at: r.poll.at,
          poll_ok: if(r.poll.state == :never, do: nil, else: r.poll.state != :failing),
          chat_state: r.chat.state,
          chat_at: r.chat.at,
          api_24h: r.coverage.api_24h
        }
      end

    [[last_webhook, oldest_unprocessed, drift]] =
      Repo.query!("""
      SELECT (SELECT max(received_at) FROM webhook_events WHERE received_at > now() - interval '2 days'),
             (SELECT min(stored_at) FROM webhook_events
               WHERE processed_at IS NULL AND event_type LIKE 'livestream.%'),
             -- our receive time minus Kick's send time, over the last hour
             (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM received_at - occurred_at))
               FROM webhook_events WHERE received_at > now() - interval '1 hour'
                 AND event_type IN ('channel.followed', 'livestream.metadata.updated'))
      """).rows

    %{
      channels: channels,
      collectors: collectors(),
      payload_issues: KickTracker.Health.payload_issues(DateTime.add(now, -1, :day)),
      last_webhook_at: last_webhook,
      oldest_unprocessed_at: oldest_unprocessed,
      clock_drift_s: drift,
      dead_letters:
        case DeadLetters.configured?() && DeadLetters.count() do
          {:ok, n} -> n
          _ -> nil
        end,
      queue_depth:
        case Health.queues() do
          {:ok, [main | _]} -> main.messages
          _ -> nil
        end
    }
  end

  @doc "Every collector seen in the last day, from their heartbeat rows."
  @spec collectors() :: [map()]
  def collectors do
    Repo.query!("""
    SELECT id, state, heartbeat_at, status FROM collector_nodes
    WHERE heartbeat_at > now() - interval '1 day' ORDER BY id
    """).rows
    |> Enum.map(fn [id, state, heartbeat_at, status] ->
      journal = status["journal"] || %{}

      %{
        id: id,
        state: state,
        heartbeat_at: heartbeat_at,
        journal_depth: journal["depth"] || 0,
        journal_oldest_at: parse_time(journal["oldest_at"]),
        journal_buried: journal["buried"] || 0,
        # Unknown for a collector whose image predates BUILD_SHA.
        build: status["build"],
        quarantined:
          for(
            q <- status["quarantined"] || [],
            do: %{
              channel_id: q["channel_id"],
              failures: q["failures"],
              since: parse_time(q["since"])
            }
          )
      }
    end)
  end

  defp parse_time(nil), do: nil

  defp parse_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  @doc "Tells someone about a new kind of error (ErrorTracker's telemetry)."
  def attach_error_notifications do
    :telemetry.attach(
      "kick-tracker-new-errors",
      [:error_tracker, :error, :new],
      &__MODULE__.handle_new_error/4,
      nil
    )
  end

  @doc false
  def handle_new_error(_event, _measurements, %{error: error}, _config) do
    Task.start(fn ->
      Notifier.send("🐛 new error: #{error.kind}: #{String.slice(error.reason, 0, 200)}")
    end)
  end

  def handle_new_error(_event, _measurements, _metadata, _config), do: :ok
end
