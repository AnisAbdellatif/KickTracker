defmodule KickTracker.Series do
  @moduledoc """
  Time series for the public site's charts (project.md §13.4, §13.5), in
  the compact column format the chart hook reads: `%{t: [unix seconds],
  <column>: [values]}`. Read-only.

  The resolution follows the range (`Series.Resolution`). Two kinds of
  "nothing" are kept apart (§13.1):

    * a bucket with no data is `nil` (the line breaks), never 0;
    * a count is 0 only when we were listening and nothing happened: chat
      counts are `nil` where chat coverage is missing.

  Each series also carries `gaps`: the stretches its source's `coverage`
  doesn't cover, drawn as "no data" shading.
  """

  import Ecto.Query

  alias KickTracker.Channels.Channel
  alias KickTracker.Metrics.Coverage
  alias KickTracker.Repo
  alias KickTracker.Series.Resolution

  # A raw line breaks when two samples are further apart than this.
  @max_gap_s 150
  @pad_s %{"api" => 60, "chat" => 60}

  ## Viewers

  @doc "Viewers over a range: avg and max per bucket (equal for raw samples)."
  @spec viewers(Channel.t(), DateTime.t(), DateTime.t(), Resolution.t() | nil) :: map()
  def viewers(%Channel{} = channel, from, to, requested \\ nil) do
    res = Resolution.choose(from, to, requested)

    base = %{
      res: Resolution.name(res),
      tz: channel.timezone,
      gaps: gaps(channel.id, "api", from, to)
    }

    Map.merge(base, viewer_columns(channel, from, to, res))
  end

  defp viewer_columns(channel, from, to, :raw) do
    rows =
      Repo.all(
        from v in "viewer_samples",
          where: v.channel_id == ^channel.id and v.observed_at >= ^from and v.observed_at < ^to,
          order_by: v.observed_at,
          select: {fragment("extract(epoch FROM ?)::bigint", v.observed_at), v.viewers}
      )

    {t, v} = Resolution.break_gaps(rows, @max_gap_s)
    %{t: t, avg: v, max: v}
  end

  defp viewer_columns(channel, from, to, :m5) do
    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM time_bucket('5 minutes', observed_at))::bigint,
               round(avg(viewers))::int, max(viewers)
        FROM viewer_samples
        WHERE channel_id = $1 AND observed_at >= $2 AND observed_at < $3
        GROUP BY 1
        """,
        [channel.id, from, to]
      ).rows

    grid = Resolution.grid(from, to, :m5)
    [avg, max] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 2)
    %{t: grid, avg: avg, max: max}
  end

  defp viewer_columns(channel, from, to, :hour) do
    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM hour)::bigint, round(avg_viewers)::int, peak_viewers
        FROM hourly_stats
        WHERE channel_id = $1 AND hour >= $2 AND hour < $3 AND samples > 0
        """,
        [channel.id, from, to]
      ).rows

    grid = Resolution.grid(from, to, :hour)
    [avg, max] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 2)
    %{t: grid, avg: avg, max: max}
  end

  defp viewer_columns(channel, from, to, :day) do
    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM (date_trunc('day', hour AT TIME ZONE $4) AT TIME ZONE $4))::bigint,
               round(sum(avg_viewers * samples) / sum(samples))::int, max(peak_viewers)
        FROM hourly_stats
        WHERE channel_id = $1 AND hour >= $2 AND hour < $3 AND samples > 0
        GROUP BY 1
        """,
        [channel.id, from, to, channel.timezone]
      ).rows

    grid = day_grid(from, to, channel.timezone)
    [avg, max] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 2)
    %{t: grid, avg: avg, max: max}
  end

  @doc "Local midnights (as unix seconds) from the day of `from` to the day before `to`, in a timezone."
  @spec day_grid(DateTime.t(), DateTime.t(), String.t()) :: [integer()]
  def day_grid(from, to, tz) do
    Repo.query!(
      """
      SELECT extract(epoch FROM (d AT TIME ZONE $3))::bigint
      FROM generate_series(date_trunc('day', $1::timestamptz AT TIME ZONE $3),
                           $2::timestamptz AT TIME ZONE $3 - interval '1 microsecond',
                           interval '1 day') AS d
      """,
      [from, to, tz]
    ).rows
    |> List.flatten()
  end

  ## Chat

  @doc """
  Messages per bucket and chatters (the most in any one minute of the
  bucket; for raw, per minute). `nil` where chat wasn't being received.
  """
  @spec chat(Channel.t(), DateTime.t(), DateTime.t(), Resolution.t() | nil) :: map()
  def chat(%Channel{} = channel, from, to, requested \\ nil) do
    res = Resolution.choose(from, to, requested)
    periods = periods(channel.id, "chat", from, to)

    {grid, width, rows} =
      case res do
        :raw ->
          rows =
            Repo.query!(
              """
              SELECT extract(epoch FROM minute)::bigint, messages, chatters FROM chat_minutes
              WHERE channel_id = $1 AND minute >= $2 AND minute < $3
              """,
              [channel.id, from, to]
            ).rows

          {minute_grid(from, to), 60, rows}

        :m5 ->
          rows =
            Repo.query!(
              """
              SELECT extract(epoch FROM time_bucket('5 minutes', minute))::bigint,
                     sum(messages)::int, max(chatters)
              FROM chat_minutes WHERE channel_id = $1 AND minute >= $2 AND minute < $3
              GROUP BY 1
              """,
              [channel.id, from, to]
            ).rows

          {Resolution.grid(from, to, :m5), 300, rows}

        :hour ->
          rows =
            Repo.query!(
              """
              SELECT extract(epoch FROM hour)::bigint, messages, NULL::int FROM hourly_stats
              WHERE channel_id = $1 AND hour >= $2 AND hour < $3
              """,
              [channel.id, from, to]
            ).rows

          {Resolution.grid(from, to, :hour), 3600, rows}

        :day ->
          rows =
            Repo.query!(
              """
              SELECT extract(epoch FROM (date_trunc('day', hour AT TIME ZONE $4) AT TIME ZONE $4))::bigint,
                     sum(messages)::int, NULL::int
              FROM hourly_stats WHERE channel_id = $1 AND hour >= $2 AND hour < $3
              GROUP BY 1
              """,
              [channel.id, from, to, channel.timezone]
            ).rows

          {day_grid(from, to, channel.timezone), 86_400, rows}
      end

    [messages, chatters] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 2)
    listening = covered_mask(grid, width, periods, @pad_s["chat"])

    %{
      res: Resolution.name(res),
      tz: channel.timezone,
      t: grid,
      messages: zero_when_listening(messages, listening),
      chatters: if(res in [:raw, :m5], do: zero_when_listening(chatters, listening), else: nil),
      gaps: gaps_from(periods, from, to, @pad_s["chat"])
    }
  end

  @doc """
  Active chatters in a rolling window (§3.4): for each minute of a
  stream, how many distinct people chatted in the `window` minutes up to
  it. Needs the per-minute detail, kept 90 days; older streams get `nil`.
  """
  @spec active_chatters(map(), pos_integer()) :: map()
  def active_chatters(%{channel_id: channel_id} = stream, window) when window in 1..60 do
    to = stream.ended_at || DateTime.utc_now()
    from = stream.started_at
    grid = minute_grid(from, to)
    periods = periods(channel_id, "chat", from, to)

    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM m)::bigint, count(DISTINCT u.user_id)::int
        FROM generate_series(date_trunc('minute', $2::timestamptz), $3::timestamptz, interval '1 minute') AS m
        JOIN chat_minute_users u
          ON u.channel_id = $1 AND u.minute > m - make_interval(mins => $4::int) AND u.minute <= m
        GROUP BY 1
        """,
        [channel_id, from, to, window]
      ).rows

    [counts] = Resolution.fill(grid, Enum.map(rows, &List.to_tuple/1), 1)

    %{
      window: window,
      t: grid,
      chatters: zero_when_listening(counts, covered_mask(grid, 60, periods, @pad_s["chat"]))
    }
  end

  ## Followers

  @doc "Follower totals: every reading up to 90 days, the day's last reading beyond."
  @spec followers(Channel.t(), DateTime.t(), DateTime.t()) :: map()
  def followers(%Channel{} = channel, from, to) do
    if DateTime.diff(to, from) <= 90 * 86_400 do
      rows =
        Repo.all(
          from f in "follower_samples",
            where: f.channel_id == ^channel.id and f.observed_at >= ^from and f.observed_at < ^to,
            order_by: f.observed_at,
            select: {fragment("extract(epoch FROM ?)::bigint", f.observed_at), f.followers}
        )

      %{res: "raw", t: Enum.map(rows, &elem(&1, 0)), v: Enum.map(rows, &elem(&1, 1))}
    else
      rows =
        Repo.query!(
          """
          SELECT extract(epoch FROM (date_trunc('day', observed_at AT TIME ZONE $4) AT TIME ZONE $4))::bigint,
                 last(followers, observed_at)
          FROM follower_samples WHERE channel_id = $1 AND observed_at >= $2 AND observed_at < $3
          GROUP BY 1 ORDER BY 1
          """,
          [channel.id, from, to, channel.timezone]
        ).rows

      %{res: "1d", t: Enum.map(rows, &hd/1), v: Enum.map(rows, &List.last/1)}
    end
  end

  ## Support

  @doc "Subs (new and renewed), gifted subs and Kicks per bucket."
  @spec support(Channel.t(), DateTime.t(), DateTime.t(), Resolution.t() | nil) :: map()
  def support(%Channel{} = channel, from, to, requested \\ nil) do
    res = Resolution.choose(from, to, requested)

    {grid, bucket} =
      case res do
        :raw ->
          {minute_grid(from, to), "date_trunc('minute', occurred_at)"}

        :m5 ->
          {Resolution.grid(from, to, :m5), "time_bucket('5 minutes', occurred_at)"}

        :hour ->
          {Resolution.grid(from, to, :hour), "date_trunc('hour', occurred_at, 'UTC')"}

        :day ->
          {day_grid(from, to, channel.timezone),
           "(date_trunc('day', occurred_at AT TIME ZONE $4) AT TIME ZONE $4)"}
      end

    rows =
      Repo.query!(
        """
        SELECT extract(epoch FROM #{bucket})::bigint,
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
    zero = &Enum.map(&1, fn v -> v || 0 end)

    %{
      res: Resolution.name(res),
      tz: channel.timezone,
      t: grid,
      subs: zero.(subs),
      gifts: zero.(gifts),
      kicks: zero.(kicks)
    }
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
      do:
        Coverage.fraction(
          periods(channel.id, source, from, to),
          from,
          to,
          Map.get(@pad_s, source, 60)
        ),
      else: 1.0
  end

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

  # Whether each bucket was mostly covered.
  defp covered_mask(grid, width, periods, pad) do
    ok = Enum.filter(periods, & &1.ok)

    Enum.map(grid, fn t ->
      from = DateTime.from_unix!(t)
      Coverage.fraction(ok, from, DateTime.add(from, width), pad) >= 0.5
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
