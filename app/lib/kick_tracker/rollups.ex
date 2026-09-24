defmodule KickTracker.Rollups do
  @moduledoc """
  The derived tables (project.md §12.6): `stream_stats` per stream and
  `hourly_stats` per channel and UTC hour. Both are caches over the raw
  tables, recomputed for recent data by `KickTracker.Workers.Rollups` and
  rebuildable for any range (`mix kick_tracker.rebuild`), so a formula can
  change and the whole history be recomputed.

  Follows, subs, gifts, Kicks and chat are counted for a stream by time:
  what happened between its start and its end (or now, while live).
  """

  import Ecto.Query

  alias KickTracker.{Metrics, Repo}

  # --- stream_stats ----------------------------------------------------------

  @doc "Recomputes one stream's figures."
  @spec stream_stats(integer()) :: :ok
  def stream_stats(stream_id) do
    %{rows: [[channel_id, started_at, ended_at]]} =
      Repo.query!("SELECT channel_id, started_at, ended_at FROM streams WHERE id = $1", [
        stream_id
      ])

    until = ended_at || DateTime.utc_now()

    samples =
      Repo.all(
        from v in "viewer_samples",
          where: v.channel_id == ^channel_id and v.stream_id == ^stream_id,
          select: {type(v.observed_at, :utc_datetime_usec), v.viewers}
      )

    window = 30 * 60

    followers =
      Repo.all(
        from f in "follower_samples",
          where:
            f.channel_id == ^channel_id and
              f.observed_at >= ^DateTime.add(started_at, -window) and
              f.observed_at <= ^DateTime.add(until, window),
          select: {type(f.observed_at, :utc_datetime_usec), f.followers}
      )

    viewers = Metrics.viewers(samples)
    gain = Metrics.follower_gain(started_at, ended_at, followers)
    counts = counts(channel_id, stream_id, started_at, until)

    row =
      Map.merge(counts, %{
        stream_id: stream_id,
        channel_id: channel_id,
        computed_at: DateTime.utc_now(),
        airtime_s: Metrics.airtime_s(started_at, ended_at),
        samples: viewers.samples,
        avg_viewers: viewers.avg,
        peak_viewers: viewers.peak,
        hours_watched: if(samples != [], do: Metrics.hours_watched(started_at, samples)),
        followers_start: gain.start,
        followers_end: gain.end,
        follower_gain: gain.gain
      })

    Repo.insert_all("stream_stats", [row],
      on_conflict: {:replace, Map.keys(row) -- [:stream_id]},
      conflict_target: :stream_id
    )

    :ok
  end

  defp counts(channel_id, stream_id, from, until) do
    %{rows: [[follows, subs, resubs, gifted, kicks, chatters, messages, new_chatters]]} =
      Repo.query!(
        """
        SELECT
          (SELECT count(*) FROM follows
            WHERE channel_id = $1 AND occurred_at >= $3 AND occurred_at <= $4),
          (SELECT count(*) FROM support_events
            WHERE channel_id = $1 AND kind = 'sub' AND occurred_at >= $3 AND occurred_at <= $4),
          (SELECT count(*) FROM support_events
            WHERE channel_id = $1 AND kind = 'resub' AND occurred_at >= $3 AND occurred_at <= $4),
          (SELECT coalesce(sum(quantity), 0) FROM support_events
            WHERE channel_id = $1 AND kind = 'gift' AND occurred_at >= $3 AND occurred_at <= $4),
          (SELECT coalesce(sum(quantity), 0) FROM support_events
            WHERE channel_id = $1 AND kind = 'kicks' AND occurred_at >= $3 AND occurred_at <= $4),
          (SELECT count(*) FROM chat_stream_users WHERE stream_id = $2),
          (SELECT coalesce(sum(messages), 0) FROM chat_stream_users WHERE stream_id = $2),
          -- chatters with no earlier stream of this channel
          (SELECT count(*) FROM chat_stream_users u WHERE u.stream_id = $2 AND NOT EXISTS (
             SELECT 1 FROM chat_stream_users u2 JOIN streams s2 ON s2.id = u2.stream_id
             WHERE u2.user_id = u.user_id AND s2.channel_id = $1 AND s2.started_at < $3))
        """,
        [channel_id, stream_id, from, until]
      )

    %{
      follows: follows,
      subs: subs,
      resubs: resubs,
      gifted_subs: to_int(gifted),
      kicks: to_int(kicks),
      unique_chatters: chatters,
      new_chatters: new_chatters,
      messages: to_int(messages)
    }
  end

  @doc """
  Recomputes `stream_stats` for streams live or ended since `since` (all
  streams when nil). Returns how many.
  """
  @spec recent_stream_stats(DateTime.t() | nil) :: non_neg_integer()
  def recent_stream_stats(since) do
    query =
      if since,
        do: from(s in "streams", where: is_nil(s.ended_at) or s.ended_at >= ^since, select: s.id),
        else: from(s in "streams", select: s.id)

    ids = Repo.all(query)
    Enum.each(ids, &stream_stats/1)
    length(ids)
  end

  # --- hourly_stats ------------------------------------------------------------

  @doc """
  Recomputes `hourly_stats` for every channel, for every UTC hour from the
  one containing `from` to the one containing `to`, both included. Rows
  are replaced, so recomputing is always safe.
  """
  @spec hourly(DateTime.t(), DateTime.t()) :: :ok
  def hourly(from, to) do
    from = truncate_hour(from)
    to = to |> truncate_hour() |> DateTime.add(3600)

    Repo.transaction(fn ->
      Repo.query!("DELETE FROM hourly_stats WHERE hour >= $1 AND hour < $2", [from, to])

      Repo.query!(
        """
        WITH weighted AS (
          SELECT v.channel_id, v.observed_at, v.viewers,
                 LEAST(
                   EXTRACT(EPOCH FROM v.observed_at - coalesce(
                     lag(v.observed_at) OVER (PARTITION BY v.stream_id ORDER BY v.observed_at),
                     s.started_at)),
                   $3) AS weight_s
          FROM viewer_samples v
          JOIN streams s ON s.id = v.stream_id
          -- a little before the range, so the first sample in it has its
          -- previous one
          WHERE v.observed_at >= $1::timestamptz - make_interval(secs => $3::int)
            AND v.observed_at < $2
            -- an excluded stream (a correction) counts in no viewer figure
            AND v.stream_id NOT IN (SELECT stream_id FROM excluded_streams)
        ),
        parts AS (
          SELECT channel_id, date_trunc('hour', observed_at, 'UTC') AS hour,
                 count(*) AS samples, avg(viewers)::float AS avg_viewers,
                 max(viewers) AS peak_viewers,
                 (sum(viewers * greatest(weight_s, 0)) / 3600)::float AS hours_watched,
                 0 AS chat_minutes, 0 AS messages, NULL::bigint AS followers_last,
                 0 AS follows, 0 AS subs, 0 AS gifted_subs, 0 AS kicks
          FROM weighted WHERE observed_at >= $1
          GROUP BY 1, 2
          UNION ALL
          SELECT channel_id, date_trunc('hour', minute, 'UTC'), 0, NULL, NULL, NULL,
                 count(*), sum(messages), NULL, 0, 0, 0, 0
          FROM chat_minutes WHERE minute >= $1 AND minute < $2
          GROUP BY 1, 2
          UNION ALL
          SELECT channel_id, date_trunc('hour', observed_at, 'UTC'), 0, NULL, NULL, NULL, 0, 0,
                 last(followers, observed_at), 0, 0, 0, 0
          FROM follower_samples WHERE observed_at >= $1 AND observed_at < $2
          GROUP BY 1, 2
          UNION ALL
          SELECT channel_id, date_trunc('hour', occurred_at, 'UTC'), 0, NULL, NULL, NULL, 0, 0,
                 NULL, count(*), 0, 0, 0
          FROM follows WHERE occurred_at >= $1 AND occurred_at < $2
          GROUP BY 1, 2
          UNION ALL
          SELECT channel_id, date_trunc('hour', occurred_at, 'UTC'), 0, NULL, NULL, NULL, 0, 0, NULL, 0,
                 count(*) FILTER (WHERE kind IN ('sub', 'resub')),
                 coalesce(sum(quantity) FILTER (WHERE kind = 'gift'), 0),
                 coalesce(sum(quantity) FILTER (WHERE kind = 'kicks'), 0)
          FROM support_events WHERE occurred_at >= $1 AND occurred_at < $2
          GROUP BY 1, 2
        )
        INSERT INTO hourly_stats
          (channel_id, hour, samples, avg_viewers, peak_viewers, hours_watched, chat_minutes,
           messages, followers_last, follows, subs, gifted_subs, kicks, computed_at)
        SELECT channel_id, hour, sum(samples), max(avg_viewers), max(peak_viewers),
               sum(hours_watched), sum(chat_minutes), sum(messages), max(followers_last),
               sum(follows), sum(subs), sum(gifted_subs), sum(kicks), now()
        FROM parts
        GROUP BY channel_id, hour
        """,
        [from, to, Metrics.cap_s()]
      )
    end)

    :ok
  end

  defp truncate_hour(%DateTime{} = at), do: %{at | minute: 0, second: 0, microsecond: {0, 6}}

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
end
