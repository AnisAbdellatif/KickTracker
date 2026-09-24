defmodule KickTracker.Alerts.Rules do
  @moduledoc """
  When to alert (project.md §18.2), from a snapshot of the collection's
  state. Pure: `evaluate/2` returns the problems present now, each with a
  stable key (the same problem keeps its key while it lasts).

  Thresholds are deliberately above normal jitter: a poll is every 60s,
  so a live channel without a reading for 5 minutes has missed five.
  """

  @type problem :: %{key: String.t(), message: String.t()}

  @no_reading_s 5 * 60
  @no_webhooks_s 30 * 60
  @live_for_s 20 * 60
  @chat_down_s 10 * 60
  @behind_s 10 * 60
  @queue_depth 1_000
  @coverage 0.95
  @drift_s 30

  @doc "The problems in a snapshot at `now`."
  @spec evaluate(map(), DateTime.t()) :: [problem()]
  def evaluate(snapshot, now) do
    channels = Enum.filter(snapshot.channels, & &1.active)

    Enum.flat_map(channels, &channel_problems(&1, now)) ++
      no_webhooks(channels, snapshot, now) ++
      queue_problems(snapshot, now) ++
      drift(snapshot)
  end

  defp channel_problems(c, now) do
    live? = c.live_since != nil
    tracked_s = DateTime.diff(now, c.tracked_since)

    [
      (live? and older_than?(c.poll_at, now, @no_reading_s) and
         DateTime.diff(now, c.live_since) > @no_reading_s) &&
        %{
          key: "no_readings:#{c.id}",
          message: "#{c.slug} is live but no viewer reading for #{ago(c.poll_at, now)}"
        },
      c.poll_ok == false &&
        %{key: "poll_failing:#{c.id}", message: "Kick's API isn't answering for #{c.slug}"},
      (tracked_s > 3600 and c.chat_state != :ok and older_than?(c.chat_at, now, @chat_down_s)) &&
        %{
          key: "chat_down:#{c.id}",
          message: "#{c.slug}'s chat has been disconnected for #{ago(c.chat_at, now)}"
        },
      (tracked_s > 86_400 and is_number(c.api_24h) and c.api_24h < @coverage) &&
        %{
          key: "coverage:#{c.id}",
          message: "#{c.slug}: only #{pct(c.api_24h)} of the last 24h was polled"
        }
    ]
    |> Enum.filter(& &1)
  end

  defp no_webhooks(channels, snapshot, now) do
    long_live =
      Enum.filter(channels, &(&1.live_since && DateTime.diff(now, &1.live_since) > @live_for_s))

    if long_live != [] and older_than?(snapshot.last_webhook_at, now, @no_webhooks_s) do
      names = long_live |> Enum.map(& &1.slug) |> Enum.join(", ")

      [
        %{
          key: "no_webhooks",
          message: "No webhook for #{ago(snapshot.last_webhook_at, now)} while live: #{names}"
        }
      ]
    else
      []
    end
  end

  defp queue_problems(snapshot, now) do
    [
      (is_integer(snapshot[:dead_letters]) and snapshot.dead_letters > 0) &&
        %{
          key: "dead_letters",
          message: "#{snapshot.dead_letters} message(s) in the dead-letter queue"
        },
      snapshot[:oldest_unprocessed_at] &&
        older_than?(snapshot.oldest_unprocessed_at, now, @behind_s) &&
        %{
          key: "consumer_behind",
          message: "Stream events unprocessed for #{ago(snapshot.oldest_unprocessed_at, now)}"
        },
      (is_integer(snapshot[:queue_depth]) and snapshot.queue_depth > @queue_depth) &&
        %{
          key: "queue_depth",
          message: "#{snapshot.queue_depth} events waiting in the queue: the consumer is behind"
        }
    ]
    |> Enum.filter(& &1)
  end

  # Our clock against Kick's, from the events' own timestamps (§19.2).
  defp drift(%{clock_drift_s: d}) when is_number(d) and abs(d) > @drift_s,
    do: [
      %{
        key: "clock_drift",
        message: "Our clock and Kick's differ by about #{round(d)}s: check NTP"
      }
    ]

  defp drift(_), do: []

  defp older_than?(nil, _now, _s), do: true
  defp older_than?(at, now, s), do: DateTime.diff(now, at) > s

  defp ago(nil, _now), do: "ever"

  defp ago(at, now) do
    s = DateTime.diff(now, at)

    cond do
      s < 5400 -> "#{div(s, 60)} min"
      s < 172_800 -> "#{div(s, 3600)} h"
      true -> "#{div(s, 86_400)} days"
    end
  end

  defp pct(f), do: "#{:erlang.float_to_binary(f * 100, decimals: 1)}%"
end
