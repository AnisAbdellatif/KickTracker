defmodule KickTracker.Health do
  @moduledoc """
  What the admin health page (project.md §13.8) and the alerts (§18.2)
  read: per channel, whether each source is working, and system-wide, the
  queue, the receivers and the jobs. Read-only, from the database (and
  RabbitMQ's management API when configured), so it works on a web node
  that runs no collection.
  """

  import Ecto.Query

  alias KickTracker.{Channels, Repo}
  alias KickTracker.Metrics.Coverage

  # How far behind a source's last outcome may be before it counts as
  # stale: a little over two cadences.
  @stale_s %{"api" => 150, "chat" => 150, "subscribers" => 660}
  # How much time one outcome vouches for (its cadence).
  @pad_s %{"api" => 60, "chat" => 60, "subscribers" => 300, "followers" => 900}

  @doc "The cadence one outcome of a source vouches for."
  def pad_s(source), do: Map.fetch!(@pad_s, source)

  @doc "One row per channel."
  @spec channels(DateTime.t()) :: [map()]
  def channels(now \\ DateTime.utc_now()) do
    channels = Channels.list_all()
    live = Channels.open_streams()
    latest = latest_outcomes()
    week_ago = DateTime.add(now, -7, :day)
    day_ago = DateTime.add(now, -1, :day)
    periods = periods_since(week_ago) |> Enum.group_by(&{&1.channel_id, &1.source})
    followers = last_by_channel("follower_samples", "observed_at")
    events = last_events()

    for c <- channels do
      source = fn s ->
        case latest[{c.id, s}] do
          nil ->
            %{state: :never, at: nil}

          %{to_at: at, ok: ok} ->
            fresh? = DateTime.diff(now, at) <= Map.get(@stale_s, s, 3600)
            %{state: state(ok, fresh?), at: at}
        end
      end

      cov = fn s, from ->
        Coverage.fraction(Map.get(periods, {c.id, s}, []), from, now, pad_s(s))
      end

      %{
        channel: c,
        live_since: live[c.id],
        poll: source.("api"),
        chat: source.("chat"),
        subscribers: source.("subscribers"),
        last_follower_reading: followers[c.id],
        last_event: events[c.kick_user_id],
        coverage: %{
          api_24h: cov.("api", day_ago),
          api_7d: cov.("api", week_ago),
          chat_24h: cov.("chat", day_ago),
          chat_7d: cov.("chat", week_ago)
        }
      }
    end
  end

  defp state(true, true), do: :ok
  defp state(false, true), do: :failing
  defp state(_ok, false), do: :stale

  defp latest_outcomes do
    Repo.query!("""
    SELECT DISTINCT ON (channel_id, source) channel_id, source, to_at, ok
    FROM coverage WHERE channel_id IS NOT NULL
    ORDER BY channel_id, source, from_at DESC, id DESC
    """).rows
    |> Map.new(fn [id, source, to_at, ok] -> {{id, source}, %{to_at: to_at, ok: ok}} end)
  end

  @doc "Coverage periods of every channel ending after `since`."
  @spec periods_since(DateTime.t()) :: [map()]
  def periods_since(since) do
    Repo.all(
      from c in "coverage",
        where: c.to_at >= ^since and not is_nil(c.channel_id),
        select: %{
          channel_id: c.channel_id,
          source: c.source,
          from_at: c.from_at,
          to_at: c.to_at,
          ok: c.ok
        }
    )
  end

  # sobelow_skip ["SQL.Query"]
  defp last_by_channel(table, column) do
    Repo.query!("SELECT channel_id, max(#{column}) FROM #{table} GROUP BY channel_id").rows
    |> Map.new(fn [id, at] -> {id, at} end)
  end

  defp last_events do
    Repo.query!("""
    SELECT broadcaster_user_id, max(received_at) FROM webhook_events
    WHERE broadcaster_user_id IS NOT NULL AND received_at > now() - interval '30 days'
    GROUP BY broadcaster_user_id
    """).rows
    |> Map.new(fn [id, at] -> {id, at} end)
  end

  @doc "Webhook intake: receivers last seen, and events waiting for their channel's process."
  @spec ingress() :: map()
  def ingress do
    receivers =
      Repo.query!("""
      SELECT receiver, max(received_at), count(*) FILTER (WHERE received_at > now() - interval '1 hour')
      FROM webhook_events WHERE received_at > now() - interval '7 days'
      GROUP BY receiver ORDER BY receiver
      """).rows
      |> Enum.map(fn [name, at, hour] -> %{name: name, last_at: at, last_hour: hour} end)

    [[unprocessed, oldest]] =
      Repo.query!(
        "SELECT count(*), min(stored_at) FROM webhook_events WHERE processed_at IS NULL"
      ).rows

    # Time from the receiver to the database, over the last hour: the
    # consumer's lag.
    [[lag]] =
      Repo.query!("""
      SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch FROM stored_at - received_at))
      FROM webhook_events WHERE received_at > now() - interval '1 hour'
      """).rows

    %{receivers: receivers, unprocessed: unprocessed, oldest_unprocessed: oldest, lag_p95_s: lag}
  end

  @doc "Webhooks that didn't have the shape we parse, seen since `since` (§19.2)."
  @spec payload_issues(DateTime.t()) :: [map()]
  def payload_issues(since) do
    Repo.all(
      from i in "payload_issues",
        where: i.last_seen_at >= ^since,
        order_by: [desc: i.last_seen_at],
        select: %{
          event_type: i.event_type,
          event_version: i.event_version,
          problem: i.problem,
          count: i.count,
          last_seen_at: i.last_seen_at,
          example_message_id: i.example_message_id
        }
    )
  end

  @doc "Oban job counts by queue and state, and recent failures."
  @spec jobs() :: map()
  def jobs do
    counts =
      Repo.query!("""
      SELECT queue, state, count(*) FROM oban_jobs
      WHERE state IN ('available', 'scheduled', 'executing', 'retryable')
         OR (state IN ('discarded', 'cancelled') AND attempted_at > now() - interval '24 hours')
      GROUP BY queue, state ORDER BY queue, state
      """).rows
      |> Enum.map(fn [q, s, n] -> %{queue: q, state: s, count: n} end)

    failures =
      Repo.query!("""
      SELECT worker, state, attempted_at, errors[array_length(errors, 1)]->>'error'
      FROM oban_jobs
      WHERE state IN ('retryable', 'discarded') AND attempted_at > now() - interval '24 hours'
      ORDER BY attempted_at DESC LIMIT 10
      """).rows
      # Oban's timestamps are UTC without a zone.
      |> Enum.map(fn [w, s, at, e] ->
        %{
          worker: w,
          state: s,
          at: DateTime.from_naive!(at, "Etc/UTC"),
          error: e && String.slice(e, 0, 300)
        }
      end)

    %{counts: counts, failures: failures}
  end

  @doc """
  The event queue and its dead letters, from RabbitMQ's management API
  (`RABBITMQ_MANAGEMENT_URL`, a read-only monitoring user). `:not_configured`
  when unset, `{:error, reason}` when RabbitMQ doesn't answer.
  """
  @spec queues() :: {:ok, [map()]} | :not_configured | {:error, term()}
  def queues do
    case Application.get_env(:kick_tracker, :rabbitmq_management_url) do
      nil ->
        :not_configured

      url ->
        vhost = Application.get_env(:kick_tracker, :rabbitmq_vhost, "/")
        queue = Application.get_env(:kick_tracker, :amqp_queue, "kick_tracker.events")

        results =
          for name <- [queue, queue <> ".dead"] do
            path = "/api/queues/#{URI.encode_www_form(vhost)}/#{URI.encode_www_form(name)}"

            case Req.get(url <> path, retry: false, receive_timeout: 5_000) do
              {:ok, %{status: 200, body: body}} ->
                {:ok,
                 %{
                   name: name,
                   messages: body["messages"],
                   unacked: body["messages_unacknowledged"],
                   consumers: body["consumers"]
                 }}

              {:ok, %{status: status}} ->
                {:error, {:http, status}}

              {:error, error} ->
                {:error, error}
            end
          end

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> {:ok, Enum.map(results, &elem(&1, 1))}
          error -> error
        end
    end
  end

  @doc """
  Kick's webhook subscriptions against the ones each active channel should
  have: `%{kick_user_id => %{have: n, want: n}}`, plus the total.
  """
  @spec subscriptions() :: {:ok, map()} | {:error, term()}
  def subscriptions do
    with {:ok, subs} <- KickTracker.Kick.API.subscriptions() do
      wanted = KickTracker.Workers.SubscriptionSync.events()

      by_user =
        subs
        |> Enum.filter(&(&1["event"] in wanted))
        |> Enum.group_by(& &1["broadcaster_user_id"], & &1["event"])
        |> Map.new(fn {id, events} -> {id, events |> Enum.uniq() |> length()} end)

      {:ok, %{by_user: by_user, want: length(wanted), total: length(subs)}}
    end
  catch
    # No token process (should not happen on a web or collector node).
    :exit, reason -> {:error, reason}
  end
end
