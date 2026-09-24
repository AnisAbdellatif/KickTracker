defmodule KickTracker.Rollups do
  @moduledoc """
  The derived tables (project.md §12.6): `stream_stats` per stream and
  `hourly_stats` per channel and UTC hour. Both are caches over the raw
  tables, recomputed for recent data by `KickTracker.Workers.Rollups` and
  rebuildable for any range (`mix kick_tracker.rebuild`), so a formula can
  change and the whole history be recomputed.

  Follows, subs, gifts, Kicks and chat are counted for a stream by time:
  what happened between its start and its end (or now, while live).
  Follows and support come from webhooks: they are counted only when
  ingress coverage covers the stream (`Series.complete?/1`), and are null
  (unknown) otherwise, never a 0 that would read as "nothing happened".
  """

  import Ecto.Query

  alias KickTracker.{Metrics, Repo, Series}

  # Rebuilds of hourly_stats take this transaction-scoped advisory lock,
  # so the 5-minute job, the nightly one and an admin's reprocessing never
  # replace the same hours at once.
  @hourly_lock 7_346_210_001
  @long_ms :timer.minutes(30)

  # --- stream_stats ----------------------------------------------------------

  @doc """
  Recomputes one stream's figures. The root of a merge group
  (`merge_groups`, project.md §13.8) is computed over every stream merged
  into it at any depth (except those excluded on their own), from its
  start to the last one's end:

    * airtime is the sum of the parts' airtimes: the drop between two
      parts isn't airtime, as in the period figures;
    * hours watched weigh each part's first sample from that part's own
      start, as `hourly_stats` does, so hourly figures add up to the
      stream's.
  """
  @spec stream_stats(integer()) :: :ok
  def stream_stats(stream_id) do
    %{rows: [[channel_id, started_at, ended_at]]} =
      Repo.query!("SELECT channel_id, started_at, ended_at FROM streams WHERE id = $1", [
        stream_id
      ])

    parts = [{stream_id, started_at, ended_at} | merged_parts(stream_id)]
    ids = Enum.map(parts, &elem(&1, 0))
    ends = Enum.map(parts, &elem(&1, 2))
    ended_at = if Enum.any?(ends, &is_nil/1), do: nil, else: Enum.max(ends, DateTime)
    until = ended_at || DateTime.utc_now()

    by_part =
      Repo.all(
        from v in "viewer_samples",
          where: v.channel_id == ^channel_id and v.stream_id in ^ids,
          select: {v.stream_id, type(v.observed_at, :utc_datetime_usec), v.viewers}
      )
      |> Enum.group_by(&elem(&1, 0), fn {_, at, v} -> {at, v} end)

    samples = by_part |> Map.values() |> List.flatten()

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

    flagged = flag_outliers(channel_id, ids, samples)
    viewers = Metrics.viewers(samples, flagged)
    gain = Metrics.follower_gain(started_at, ended_at, followers)
    counts = counts(channel_id, ids, started_at, until)

    row =
      Map.merge(counts, %{
        stream_id: stream_id,
        channel_id: channel_id,
        computed_at: DateTime.utc_now(),
        airtime_s: airtime_s(parts),
        samples: viewers.samples,
        avg_viewers: viewers.avg,
        peak_viewers: viewers.peak,
        hours_watched: hours_watched(parts, by_part),
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

  # The streams merged into a root, at any depth, as `{id, started_at,
  # ended_at}`; none for a stream that is itself merged into another.
  # A part excluded on its own stays out of its root's figures.
  defp merged_parts(stream_id) do
    Repo.query!(
      """
      SELECT s.id, s.started_at, s.ended_at FROM merge_groups g JOIN streams s ON s.id = g.stream_id
      WHERE g.root_id = $1
        AND NOT EXISTS (SELECT 1 FROM merge_groups up WHERE up.stream_id = $1)
        AND s.id NOT IN (SELECT stream_id FROM stream_overrides
                         WHERE kind = 'exclude' AND revoked_at IS NULL)
      ORDER BY s.started_at
      """,
      [stream_id]
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end

  @doc "Airtime of a stream's parts `{id, started_at, ended_at}`: their sum, nil while one is live."
  @spec airtime_s([{integer(), DateTime.t(), DateTime.t() | nil}]) :: non_neg_integer() | nil
  def airtime_s(parts) do
    airtimes = Enum.map(parts, fn {_, from, to} -> Metrics.airtime_s(from, to) end)
    if Enum.any?(airtimes, &is_nil/1), do: nil, else: Enum.sum(airtimes)
  end

  @doc """
  Hours watched of a stream's parts, each weighted from its own start;
  nil without samples.
  """
  @spec hours_watched([{integer(), DateTime.t(), term()}], %{integer() => list()}) ::
          float() | nil
  def hours_watched(parts, by_part) do
    if Enum.all?(parts, fn {id, _, _} -> Map.get(by_part, id, []) == [] end) do
      nil
    else
      parts
      |> Enum.map(fn {id, from, _} -> Metrics.hours_watched(from, Map.get(by_part, id, [])) end)
      |> Enum.sum()
    end
  end

  @doc """
  Recomputes the outlier flags of these streams' samples (`viewer_flags`,
  derived) and returns the flagged moments.
  """
  @spec flag_outliers(integer(), [integer()], [{DateTime.t(), integer()}]) :: MapSet.t()
  def flag_outliers(channel_id, stream_ids, samples) do
    flags = Metrics.Outliers.flags(samples)

    Repo.transaction(fn ->
      Repo.query!("DELETE FROM viewer_flags WHERE stream_id = ANY($1)", [stream_ids])

      Repo.insert_all(
        "viewer_flags",
        for(
          {at, reason} <- flags,
          do: %{
            channel_id: channel_id,
            observed_at: at,
            stream_id: hd(stream_ids),
            reason: to_string(reason)
          }
        ),
        on_conflict: :nothing
      )
    end)

    MapSet.new(flags, &elem(&1, 0))
  end

  defp flag_range(from, to) do
    Repo.query!(
      """
      SELECT s.id, s.channel_id FROM streams s
      WHERE s.started_at < $2 AND (s.ended_at IS NULL OR s.ended_at > $1)
      """,
      [from, to],
      timeout: @long_ms
    ).rows
    |> Enum.each(fn [stream_id, channel_id] ->
      samples =
        Repo.all(
          from(v in "viewer_samples",
            where: v.channel_id == ^channel_id and v.stream_id == ^stream_id,
            select: {type(v.observed_at, :utc_datetime_usec), v.viewers}
          ),
          timeout: @long_ms
        )

      flag_outliers(channel_id, [stream_id], samples)
    end)
  end

  defp counts(channel_id, stream_ids, from, until) do
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
          (SELECT count(DISTINCT user_id) FROM chat_stream_users WHERE stream_id = ANY($2)),
          (SELECT coalesce(sum(messages), 0) FROM chat_stream_users WHERE stream_id = ANY($2)),
          -- chatters with no earlier stream of this channel (an excluded
          -- stream isn't one: it counts in no figure)
          (SELECT count(DISTINCT u.user_id) FROM chat_stream_users u WHERE u.stream_id = ANY($2) AND NOT EXISTS (
             SELECT 1 FROM chat_stream_users u2 JOIN streams s2 ON s2.id = u2.stream_id
             WHERE u2.user_id = u.user_id AND s2.channel_id = $1 AND s2.started_at < $3
               AND NOT s2.id = ANY($2)
               AND s2.id NOT IN (SELECT stream_id FROM excluded_streams)))
        """,
        [channel_id, stream_ids, from, until]
      )

    # Webhook counts are known only where the ingress covered the stream.
    known? = Series.complete?(Series.covered_fraction(channel_id, "ingress", from, until))
    known = fn v -> if known?, do: to_int(v) end

    %{
      follows: known.(follows),
      subs: known.(subs),
      resubs: known.(resubs),
      gifted_subs: known.(gifted),
      kicks: known.(kicks),
      unique_chatters: chatters,
      new_chatters: new_chatters,
      messages: to_int(messages)
    }
  end

  @doc """
  Recomputes `stream_stats` for streams live or ended since `since` (all
  streams when nil), and for the roots of their merge groups. Returns how
  many.
  """
  @spec recent_stream_stats(DateTime.t() | nil) :: non_neg_integer()
  def recent_stream_stats(since) do
    query =
      if since,
        do: from(s in "streams", where: is_nil(s.ended_at) or s.ended_at >= ^since, select: s.id),
        else: from(s in "streams", select: s.id)

    ids = Repo.all(query)
    ids = Enum.uniq(ids ++ roots(ids))
    Enum.each(ids, &stream_stats/1)
    length(ids)
  end

  @doc "The roots of the merge groups these streams belong to (none for roots themselves)."
  @spec roots([integer()]) :: [integer()]
  def roots([]), do: []

  def roots(ids) do
    Repo.all(
      from g in "merge_groups", where: g.stream_id in ^ids, distinct: true, select: g.root_id
    )
  end

  @doc """
  The time of the earliest raw fact of any kind (nil with none): where a
  full rebuild starts, so chat, follows, support and follower readings
  from before the first stream are rolled up too.
  """
  @spec earliest_fact() :: DateTime.t() | nil
  def earliest_fact do
    %{rows: [[at]]} =
      Repo.query!(
        """
        SELECT least(
          (SELECT min(started_at) FROM streams),
          (SELECT min(observed_at) FROM viewer_samples),
          (SELECT min(minute) FROM chat_minutes),
          (SELECT min(observed_at) FROM follower_samples),
          (SELECT min(occurred_at) FROM follows),
          (SELECT min(occurred_at) FROM support_events))
        """,
        [],
        timeout: @long_ms
      )

    at
  end

  # --- hourly_stats ------------------------------------------------------------

  @doc """
  Recomputes `hourly_stats` for every channel, for every UTC hour from the
  one containing `from` to the one containing `to`, both included. Rows
  are replaced, so recomputing is always safe, also while another rebuild
  of overlapping hours runs (they take turns on an advisory lock, and rows
  are upserted).

  Viewer figures leave excluded streams out (`excluded_streams`); follows,
  chat and support count everything that happened in the channel.
  """
  @spec hourly(DateTime.t(), DateTime.t()) :: :ok
  # sobelow_skip ["SQL.Query"]
  def hourly(from, to) do
    from = truncate_hour(from)
    to = to |> truncate_hour() |> DateTime.add(3600)

    {:ok, :ok} =
      Repo.transaction(
        fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1)", [@hourly_lock], timeout: @long_ms)

          # The peaks below leave flagged readings out: flag first.
          flag_range(from, to)

          Repo.query!("DELETE FROM hourly_stats WHERE hour >= $1 AND hour < $2", [from, to],
            timeout: @long_ms
          )

          Repo.query!(hourly_sql(), [from, to, Metrics.cap_s()], timeout: @long_ms)
          :ok
        end,
        timeout: @long_ms
      )

    :ok
  end

  defp hourly_sql do
    """
    WITH weighted AS (
      SELECT v.channel_id, v.observed_at, v.viewers,
             EXISTS (SELECT 1 FROM viewer_flags f
                     WHERE f.channel_id = v.channel_id AND f.observed_at = v.observed_at) AS flagged,
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
             -- a flagged reading (a glitch) is never a peak (§19.2)
             max(viewers) FILTER (WHERE NOT flagged) AS peak_viewers,
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
    ON CONFLICT (channel_id, hour) DO UPDATE SET
      samples = EXCLUDED.samples, avg_viewers = EXCLUDED.avg_viewers,
      peak_viewers = EXCLUDED.peak_viewers, hours_watched = EXCLUDED.hours_watched,
      chat_minutes = EXCLUDED.chat_minutes, messages = EXCLUDED.messages,
      followers_last = EXCLUDED.followers_last, follows = EXCLUDED.follows,
      subs = EXCLUDED.subs, gifted_subs = EXCLUDED.gifted_subs, kicks = EXCLUDED.kicks,
      computed_at = EXCLUDED.computed_at
    """
  end

  defp truncate_hour(%DateTime{} = at), do: %{at | minute: 0, second: 0, microsecond: {0, 6}}

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
end
