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

  @doc "Checks now: opens, reminds and resolves alerts. Returns the open ones."
  @spec run(DateTime.t(), (String.t() -> term())) :: [map()]
  def run(now \\ DateTime.utc_now(), notify \\ &Notifier.send/1) do
    problems = snapshot(now) |> Rules.evaluate(now) |> Map.new(&{&1.key, &1})

    open =
      Repo.all(
        from a in "alerts",
          where: is_nil(a.resolved_at),
          select: %{id: a.id, key: a.key, notified_at: a.notified_at, message: a.message}
      )

    open_keys = MapSet.new(open, & &1.key)

    for a <- open do
      case problems[a.key] do
        nil ->
          Repo.update_all(from(x in "alerts", where: x.id == ^a.id), set: [resolved_at: now])
          notify.("✅ resolved: " <> a.message)

        p ->
          remind? = a.notified_at == nil or DateTime.diff(now, a.notified_at) > @remind_s
          if remind?, do: notify.("🔴 still: " <> p.message)

          Repo.update_all(from(x in "alerts", where: x.id == ^a.id),
            set:
              [last_at: now, message: p.message] ++ if(remind?, do: [notified_at: now], else: [])
          )
      end
    end

    for {key, p} <- problems, not MapSet.member?(open_keys, key) do
      notify.("🔴 " <> p.message)

      Repo.insert_all(
        "alerts",
        [%{key: key, message: p.message, first_at: now, last_at: now, notified_at: now}],
        on_conflict: :nothing
      )
    end

    open_alerts()
  end

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
