defmodule KickTracker.Series do
  @moduledoc """
  Time series for the public site's charts (project.md §13.4, §13.5), in
  the compact column format the chart hook reads: `%{t: [unix seconds],
  <column>: [values]}`. Read-only.

  The resolution follows the range (`Series.Resolution`), so no series
  has more than 2 000 points. Two kinds of "nothing" are kept apart
  (§13.1):

    * a bucket with no data is `nil` (the line breaks), never 0;
    * a count is 0 only when we were listening and nothing happened: chat
      counts are `nil` where chat coverage is missing, subs, gifts and
      Kicks where ingress coverage is.

  Each series also carries `gaps`: the stretches its source's `coverage`
  doesn't cover, drawn as "no data" shading.

  Viewer figures follow the rollups: an excluded stream's readings are
  left out, and a flagged reading (`viewer_flags`, §19.2) counts in the
  average but is never a bucket's max.
  """

  import Ecto.Query

  alias KickTracker.Channels.Channel
  alias KickTracker.Metrics.Coverage
  alias KickTracker.Repo
  alias KickTracker.Series.Resolution

  # A raw line breaks when two samples are further apart than this.
  @max_gap_s 150
  # How long after a period's last outcome it still vouches for: a little
  # over the source's cadence (ingress: the 15-minute subscription check).
  @pad_s %{"api" => 60, "chat" => 60, "ingress" => 960}
  # The share of a range a source must cover for a count over it to be
  # known, rather than null.
  @complete 0.99
  # chat_minute_users is dropped after this long (retention policy).
  @chat_detail_days 90

  ## Viewers

  @doc """
  Viewers over a range: avg and max per bucket (equal for raw samples,
  except that a flagged reading has no max). `opts[:stream_ids]` limits
  the readings to those streams (a stream's own page, excluded or not);
  otherwise excluded streams are left out.
  """
  @spec viewers(Channel.t(), DateTime.t(), DateTime.t(), Resolution.t() | nil, keyword()) ::
          map()
  def viewers(%Channel{} = channel, from, to, requested \\ nil, opts \\ []) do
    res = Resolution.choose(from, to, requested)

    base = %{
      res: Resolution.name(res),
      tz: channel.timezone,
      gaps: gaps(channel.id, "api", from, to)
    }

    Map.merge(base, viewer_columns(channel, from, to, res, opts[:stream_ids]))
  end

  # Which readings count: those of the given streams, or every stream not
  # excluded. `$4` is the stream ids or NULL.
  @scope """
  (($4::bigint[] IS NULL AND v.stream_id NOT IN (SELECT stream_id FROM excluded_streams))
   OR v.stream_id = ANY($4::bigint[]))
  """
  @flagged "EXISTS (SELECT 1 FROM viewer_flags f WHERE f.channel_id = v.channel_id AND f.observed_at = v.observed_at)"

  defp viewer_columns(channel, from, to, :raw, ids) do
    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM v.observed_at)::bigint, v.viewers, #{@flagged}
        FROM viewer_samples v
        WHERE v.channel_id = $1 AND v.observed_at >= $2 AND v.observed_at < $3 AND #{@scope}
        ORDER BY 1
        """,
        [channel.id, from, to, ids]
      ).rows
      |> Enum.map(fn [t, v, flagged?] -> {t, {v, if(flagged?, do: nil, else: v)}} end)

    {t, vs} = Resolution.break_gaps(rows, @max_gap_s)
    %{t: t, avg: Enum.map(vs, &(&1 && elem(&1, 0))), max: Enum.map(vs, &(&1 && elem(&1, 1)))}
  end

  defp viewer_columns(channel, from, to, res, ids) when res in [:m5, :m15] do
    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM time_bucket(make_interval(secs => $5), v.observed_at))::bigint,
               round(avg(v.viewers))::int, max(v.viewers) FILTER (WHERE NOT #{@flagged})
        FROM viewer_samples v
        WHERE v.channel_id = $1 AND v.observed_at >= $2 AND v.observed_at < $3 AND #{@scope}
        GROUP BY 1
        """,
        [channel.id, from, to, ids, Resolution.width_s(res)]
      ).rows

    grid = Resolution.grid(from, to, res)
    [avg, max] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 2)
    %{t: grid, avg: avg, max: max}
  end

  # sobelow_skip ["SQL.Query"]
  defp viewer_columns(channel, from, to, res, _ids) do
    bucket = bucket_sql(res, "hour", "$4")

    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM #{bucket})::bigint,
               round(sum(avg_viewers * samples) / sum(samples))::int, max(peak_viewers)
        FROM hourly_stats
        WHERE channel_id = $1 AND hour >= $2 AND hour < $3 AND samples > 0 AND $4::text IS NOT NULL
        GROUP BY 1
        """,
        [channel.id, from, to, channel.timezone]
      ).rows

    grid = grid(from, to, res, channel.timezone)
    [avg, max] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 2)
    %{t: grid, avg: avg, max: max}
  end

  # The SQL for a column's bucket; `tz` is the placeholder of the timezone.
  # sobelow_skip ["SQL.Query"]
  defp bucket_sql(:raw, col, _tz), do: "date_trunc('minute', #{col})"
  defp bucket_sql(:m5, col, _tz), do: "time_bucket('5 minutes', #{col})"
  defp bucket_sql(:m15, col, _tz), do: "time_bucket('15 minutes', #{col})"
  defp bucket_sql(:hour, col, _tz), do: "date_trunc('hour', #{col}, 'UTC')"
  defp bucket_sql(:h6, col, _tz), do: "time_bucket('6 hours', #{col})"

  defp bucket_sql(:day, col, tz),
    do: "(date_trunc('day', #{col} AT TIME ZONE #{tz}) AT TIME ZONE #{tz})"

  defp bucket_sql(:week, col, tz),
    do: "(date_trunc('week', #{col} AT TIME ZONE #{tz}) AT TIME ZONE #{tz})"

  # The buckets of a range, as unix seconds.
  defp grid(from, to, :raw, _tz), do: minute_grid(from, to)
  defp grid(from, to, :day, tz), do: day_grid(from, to, tz)
  defp grid(from, to, :week, tz), do: local_grid(from, to, tz, "week")
  defp grid(from, to, res, _tz), do: Resolution.grid(from, to, res)

  @doc "Local midnights (as unix seconds) from the day of `from` to the day before `to`, in a timezone."
  @spec day_grid(DateTime.t(), DateTime.t(), String.t()) :: [integer()]
  def day_grid(from, to, tz), do: local_grid(from, to, tz, "day")

  # sobelow_skip ["SQL.Query"]
  defp local_grid(from, to, tz, unit) when unit in ~w(day week) do
    Repo.query!(
      """
      SELECT extract(epoch FROM (d AT TIME ZONE $3))::bigint
      FROM generate_series(date_trunc('#{unit}', $1::timestamptz AT TIME ZONE $3),
                           $2::timestamptz AT TIME ZONE $3 - interval '1 microsecond',
                           interval '1 #{unit}') AS d
      """,
      [from, to, tz]
    ).rows
    |> List.flatten()
  end

  ## Chat

  @doc """
  Messages per bucket and chatters (the most in any one minute of the
  bucket; for raw, per minute; only up to 15-minute buckets). `nil` where
  chat wasn't being received.
  """
  @spec chat(Channel.t(), DateTime.t(), DateTime.t(), Resolution.t() | nil) :: map()
  # sobelow_skip ["SQL.Query"]
  def chat(%Channel{} = channel, from, to, requested \\ nil) do
    res = Resolution.choose(from, to, requested)
    periods = periods(channel.id, "chat", from, to)
    grid = grid(from, to, res, channel.timezone)

    rows =
      if res in [:raw, :m5, :m15] do
        Repo.query!(
          """
          SELECT extract(epoch FROM #{bucket_sql(res, "minute", "$4")})::bigint,
                 sum(messages)::int, max(chatters)
          FROM chat_minutes WHERE channel_id = $1 AND minute >= $2 AND minute < $3
            AND $4::text IS NOT NULL
          GROUP BY 1
          """,
          [channel.id, from, to, channel.timezone]
        ).rows
      else
        Repo.query!(
          """
          SELECT extract(epoch FROM #{bucket_sql(res, "hour", "$4")})::bigint,
                 sum(messages)::int, NULL::int
          FROM hourly_stats WHERE channel_id = $1 AND hour >= $2 AND hour < $3
            AND $4::text IS NOT NULL
          GROUP BY 1
          """,
          [channel.id, from, to, channel.timezone]
        ).rows
      end

    [messages, chatters] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 2)
    listening = covered_mask(grid, to, periods, @pad_s["chat"])

    %{
      res: Resolution.name(res),
      tz: channel.timezone,
      t: grid,
      messages: zero_when_listening(messages, listening),
      chatters:
        if(res in [:raw, :m5, :m15], do: zero_when_listening(chatters, listening), else: nil),
      gaps: gaps_from(periods, from, to, @pad_s["chat"])
    }
  end

  @doc """
  Active chatters in a rolling window (§3.4): for each minute of a
  stream, how many distinct people chatted in the `window` minutes up to
  it. Needs the per-minute detail, kept 90 days: a minute whose window
  reaches before that is `nil` (not retained), as is one chat coverage
  says we weren't listening in. `opts[:now]` is the present, for tests.
  """
  @spec active_chatters(map(), pos_integer(), keyword()) :: map()
  def active_chatters(%{channel_id: channel_id} = stream, window, opts \\ [])
      when window in 1..60 do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    to = stream.ended_at || now
    from = stream.started_at
    grid = minute_grid(from, to)
    periods = periods(channel_id, "chat", from, to)

    # Each chatter-minute counts for the `window` minutes starting at it.
    # Every bound is on u.minute itself, so only the stream's chunks and
    # index range are read (the old join on generate_series read the
    # channel's whole history for every minute).
    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM m)::bigint, count(DISTINCT u.user_id)::int
        FROM chat_minute_users u
        CROSS JOIN LATERAL generate_series(u.minute, u.minute + make_interval(mins => $4::int - 1),
                                           interval '1 minute') AS m
        WHERE u.channel_id = $1
          AND u.minute > date_trunc('minute', $2::timestamptz) - make_interval(mins => $4::int)
          AND u.minute < $3
          AND m >= date_trunc('minute', $2::timestamptz) AND m < $3
        GROUP BY 1
        """,
        [channel_id, from, to, window]
      ).rows

    [counts] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 1)
    retained_from = DateTime.to_unix(chat_detail_since(now))
    listening = covered_mask(grid, to, periods, @pad_s["chat"])

    # Where the window's detail was dropped, the count is unknown.
    retained = Enum.map(grid, &(&1 - (window - 1) * 60 >= retained_from))

    %{
      window: window,
      t: grid,
      chatters:
        counts
        |> zero_when_listening(listening)
        |> Enum.zip_with(retained, fn v, kept? -> if kept?, do: v end)
    }
  end

  @doc "From when per-minute chatter detail (`chat_minute_users`) is kept."
  @spec chat_detail_since(DateTime.t()) :: DateTime.t()
  def chat_detail_since(now \\ DateTime.utc_now()),
    do: DateTime.add(now, -@chat_detail_days, :day)

  ## Followers

  @doc """
  Follower totals. Up to 12 hours, every reading; beyond, one point per
  bucket of the range's resolution that has readings: the last reading
  (`v`), and the lowest and highest (`min`, `max`), so no series exceeds
  2 000 points. Buckets without readings are left out: a total between
  two readings is known to lie between them.
  """
  @spec followers(Channel.t(), DateTime.t(), DateTime.t(), Resolution.t() | nil) :: map()
  # sobelow_skip ["SQL.Query"]
  def followers(%Channel{} = channel, from, to, requested \\ nil) do
    res = Resolution.choose(from, to, requested)

    rows =
      if res == :raw do
        Repo.query!(
          """
          SELECT extract(epoch FROM observed_at)::bigint, followers, followers, followers
          FROM follower_samples WHERE channel_id = $1 AND observed_at >= $2 AND observed_at < $3
          ORDER BY 1
          """,
          [channel.id, from, to]
        ).rows
      else
        Repo.query!(
          """
          SELECT extract(epoch FROM #{bucket_sql(res, "observed_at", "$4")})::bigint,
                 last(followers, observed_at), min(followers), max(followers)
          FROM follower_samples WHERE channel_id = $1 AND observed_at >= $2 AND observed_at < $3
            AND $4::text IS NOT NULL
          GROUP BY 1 ORDER BY 1
          """,
          [channel.id, from, to, channel.timezone]
        ).rows
      end

    %{
      res: Resolution.name(res),
      tz: channel.timezone,
      t: Enum.map(rows, &Enum.at(&1, 0)),
      v: Enum.map(rows, &Enum.at(&1, 1)),
      min: Enum.map(rows, &Enum.at(&1, 2)),
      max: Enum.map(rows, &Enum.at(&1, 3))
    }
  end

  ## Support

  @doc """
  Subs (new and renewed), gifted subs and Kicks per bucket. They arrive
  by webhook: a bucket is 0 only when ingress coverage says we were
  receiving, `nil` otherwise; `gaps` are the stretches not covered.
  """
  @spec support(Channel.t(), DateTime.t(), DateTime.t(), Resolution.t() | nil) :: map()
  # sobelow_skip ["SQL.Query"]
  def support(%Channel{} = channel, from, to, requested \\ nil) do
    res = Resolution.choose(from, to, requested)
    grid = grid(from, to, res, channel.timezone)
    periods = periods(channel.id, "ingress", from, to)

    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM #{bucket_sql(res, "occurred_at", "$4")})::bigint,
               count(*) FILTER (WHERE kind IN ('sub', 'resub'))::int,
               coalesce(sum(quantity) FILTER (WHERE kind = 'gift'), 0)::int,
               coalesce(sum(quantity) FILTER (WHERE kind = 'kicks'), 0)::int
        FROM support_events WHERE channel_id = $1 AND occurred_at >= $2 AND occurred_at < $3
          AND $4::text IS NOT NULL
        GROUP BY 1
        """,
        [channel.id, from, to, channel.timezone]
      ).rows

    [subs, gifts, kicks] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 3)
    listening = covered_mask(grid, to, periods, @pad_s["ingress"])

    %{
      res: Resolution.name(res),
      tz: channel.timezone,
      t: grid,
      subs: zero_when_listening(subs, listening),
      gifts: zero_when_listening(gifts, listening),
      kicks: zero_when_listening(kicks, listening),
      gaps: gaps_from(periods, from, to, @pad_s["ingress"])
    }
  end

  ## Timezones

  @doc """
  Whether the timezone is a whole number of hours from UTC over the range.
  Daily and weekday figures are built from UTC hours (`hourly_stats`), so
  for a zone like +05:30 each local day is off by the odd half hour.
  """
  @spec whole_hour_offsets?(String.t(), DateTime.t(), DateTime.t()) :: boolean()
  def whole_hour_offsets?(tz, from, to) do
    %{rows: [[whole?]]} =
      Repo.query!(
        """
        SELECT bool_and(extract(epoch FROM (t AT TIME ZONE $1) - (t AT TIME ZONE 'UTC'))::int % 3600 = 0)
        FROM unnest(ARRAY[$2::timestamptz, $3::timestamptz]) AS t
        """,
        [tz, from, to]
      )

    whole? != false
  end

  ## Coverage

  @doc """
  The share of `[from, to)` a source covered for a channel, counted from
  when tracking began and up to now.
  """
  @spec coverage(Channel.t(), String.t(), DateTime.t(), DateTime.t()) :: float()
  def coverage(%Channel{} = channel, source, from, to) do
    from = Enum.max([from, channel.tracked_since], DateTime)
    to = Enum.min([to, DateTime.utc_now()], DateTime)

    if DateTime.compare(from, to) == :lt,
      do: covered_fraction(channel.id, source, from, to),
      else: 1.0
  end

  @doc "The share of `[from, to)` a source covered for a channel (1.0 for an empty range)."
  @spec covered_fraction(integer(), String.t(), DateTime.t(), DateTime.t()) :: float()
  def covered_fraction(channel_id, source, from, to) do
    if DateTime.compare(from, to) == :lt,
      do:
        Coverage.fraction(
          periods(channel_id, source, from, to),
          from,
          to,
          Map.get(@pad_s, source, 60)
        ),
      else: 1.0
  end

  @doc """
  Whether a covered share is enough for a count over the range to be
  known: 99%, so a count is null when a stretch of any length that matters
  wasn't covered.
  """
  @spec complete?(float()) :: boolean()
  def complete?(fraction), do: fraction >= @complete

  @doc "The coverage periods of one channel and source touching `[from, to)`."
  @spec periods(integer(), String.t(), DateTime.t(), DateTime.t()) :: [map()]
  def periods(channel_id, source, from, to) do
    pad = Map.get(@pad_s, source, 60)

    Repo.all(
      from c in "coverage",
        where: c.channel_id == ^channel_id and c.source == ^source,
        where: c.to_at >= ^DateTime.add(from, -pad) and c.from_at < ^to,
        select: %{from_at: c.from_at, to_at: c.to_at, ok: c.ok}
    )
  end

  @doc "The uncovered stretches of a source, as `[from, to]` unix pairs."
  @spec gaps(integer(), String.t(), DateTime.t(), DateTime.t()) :: [[integer()]]
  def gaps(channel_id, source, from, to),
    do: gaps_from(periods(channel_id, source, from, to), from, to, Map.get(@pad_s, source, 60))

  defp gaps_from(periods, from, to, pad) do
    # Clamp to now: the future isn't a gap.
    to = Enum.min([to, DateTime.utc_now()], DateTime)

    if DateTime.compare(to, from) == :gt do
      periods
      |> Coverage.gaps(from, to, pad)
      |> Enum.map(fn {a, b} -> [DateTime.to_unix(a), DateTime.to_unix(b)] end)
    else
      []
    end
  end

  # Whether each bucket was mostly covered. A bucket runs to the next
  # one's start (days and weeks vary with daylight saving), the last to
  # `to`, and only up to now: the future is neither.
  defp covered_mask(grid, to, periods, pad) do
    ok = Enum.filter(periods, & &1.ok)
    now = DateTime.utc_now()
    ends = tl(grid) ++ [DateTime.to_unix(to)]

    Enum.zip_with(grid, ends, fn t, e ->
      from = DateTime.from_unix!(t)
      e = Enum.min([DateTime.from_unix!(max(e, t + 1)), now], DateTime)

      DateTime.compare(e, from) == :gt and Coverage.fraction(ok, from, e, pad) >= 0.5
    end)
  end

  defp zero_when_listening(values, mask) do
    Enum.zip_with(values, mask, fn
      nil, true -> 0
      v, true -> v
      _v, false -> nil
    end)
  end

  defp minute_grid(from, to) do
    first = div(DateTime.to_unix(from), 60) * 60
    last = DateTime.to_unix(to) - 1
    if last < first, do: [], else: Enum.to_list(first..last//60)
  end
end
