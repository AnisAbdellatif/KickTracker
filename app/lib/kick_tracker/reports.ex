defmodule KickTracker.Reports do
  @moduledoc """
  Figures for the public site (project.md §13.2): KPI cards, stream lists,
  leaderboards, categories, the weekday × hour heatmap, records, chatter
  overlap. Read-only, over the raw tables and the rollups.

  Unknown stays `nil` (§12.6 "Unknown Is Null"): an average with no
  samples, a follower gain without readings near both ends.
  """

  import Ecto.Query

  alias KickTracker.Channels.Channel
  alias KickTracker.{Metrics, Repo, Series}

  # At most this many gift and Kicks markers on a stream's chart.
  @max_markers 30

  ## Channels

  @doc """
  Public channels: tracked ones, including paused (their history stays
  public), but not those hidden at the streamer's request.
  """
  @spec channels() :: [Channel.t()]
  def channels, do: Repo.all(from c in Channel, where: c.public, order_by: c.slug)

  @spec channel_by_slug(String.t()) :: Channel.t() | nil
  def channel_by_slug(slug) do
    Repo.one(
      from c in Channel,
        where: c.public and fragment("lower(?)", c.slug) == ^String.downcase(slug)
    ) ||
      Repo.one(
        from c in Channel,
          join: s in "channel_slugs",
          on: s.channel_id == c.id,
          where: c.public and fragment("lower(?)", s.slug) == ^String.downcase(slug),
          limit: 1
      )
  end

  @doc "Channels whose slug contains `q`."
  @spec search(String.t()) :: [Channel.t()]
  def search(q) do
    like =
      "%" <> String.replace(String.downcase(String.trim(q)), ~w(% _ \\), &("\\" <> &1)) <> "%"

    Repo.all(
      from c in Channel,
        where: c.public and fragment("lower(?) LIKE ?", c.slug, ^like),
        order_by: c.slug,
        limit: 20
    )
  end

  ## Live now

  @doc """
  Channels on air now: the open stream, the latest reading (if recent),
  its category and title.
  """
  @spec live_now() :: [map()]
  def live_now do
    Repo.query!("""
    SELECT c.id, c.slug, s.id, s.started_at, v.viewers, v.observed_at, cat.name,
           (SELECT new_value FROM stream_changes sc
             WHERE sc.stream_id = s.id AND sc.field = 'title'
             ORDER BY occurred_at DESC LIMIT 1)
    FROM streams s
    JOIN channels c ON c.id = s.channel_id
    LEFT JOIN LATERAL (
      SELECT viewers, observed_at, category_id FROM viewer_samples
      WHERE channel_id = s.channel_id AND stream_id = s.id
        AND observed_at > now() - interval '1 day'
      ORDER BY observed_at DESC LIMIT 1
    ) v ON true
    LEFT JOIN categories cat ON cat.id = v.category_id
    WHERE s.ended_at IS NULL AND c.public
    ORDER BY v.viewers DESC NULLS LAST
    """).rows
    |> Enum.map(fn [cid, slug, sid, started, viewers, at, category, title] ->
      fresh? = at && DateTime.diff(DateTime.utc_now(), at) < 300

      %{
        channel_id: cid,
        slug: slug,
        stream_id: sid,
        started_at: started,
        viewers: if(fresh?, do: viewers),
        observed_at: at,
        category: category,
        title: title
      }
    end)
  end

  @doc "Viewers of the last few hours, 5-minute buckets, for live sparklines."
  @spec sparklines([integer()], pos_integer()) :: %{integer() => [integer() | nil]}
  def sparklines(channel_ids, hours \\ 3) do
    since = DateTime.add(DateTime.utc_now(), -hours * 3600)
    grid = KickTracker.Series.Resolution.grid(since, DateTime.utc_now(), :m5)

    rows =
      Repo.query!(
        """
        SELECT channel_id, extract(epoch FROM time_bucket('5 minutes', observed_at))::bigint,
               round(avg(viewers))::int
        FROM viewer_samples WHERE channel_id = ANY($1) AND observed_at >= $2
        GROUP BY 1, 2
        """,
        [channel_ids, since]
      ).rows
      |> Enum.group_by(&hd/1, fn [_, t, v] -> {t, v} end)

    Map.new(channel_ids, fn id ->
      [v] = KickTracker.Series.Resolution.fill(grid, Map.get(rows, id, []), 1)
      {id, v}
    end)
  end

  ## KPIs

  @doc """
  A channel's figures over `[from, to)`, each with the previous period of
  the same length for comparison: `%{now: map, before: map}`.
  """
  @spec kpis(Channel.t(), DateTime.t(), DateTime.t()) :: %{now: map(), before: map()}
  def kpis(%Channel{} = channel, from, to) do
    span = DateTime.diff(to, from)
    %{now: period(channel, from, to), before: period(channel, DateTime.add(from, -span), from)}
  end

  @doc "A channel's figures over one period."
  @spec period(Channel.t(), DateTime.t(), DateTime.t()) :: map()
  def period(%Channel{id: id} = channel, from, to) do
    [[hw, samples, avg, peak, follows, subs, gifts, kicks, messages]] =
      Repo.query!(
        """
        SELECT sum(hours_watched), sum(samples),
               sum(avg_viewers * samples) / nullif(sum(samples), 0), max(peak_viewers),
               sum(follows), sum(subs), sum(gifted_subs), sum(kicks), sum(messages)
        FROM hourly_stats WHERE channel_id = $1 AND hour >= $2 AND hour < $3
        """,
        [id, from, to]
      ).rows

    [[streams, airtime]] =
      Repo.query!(
        """
        SELECT count(*) FILTER (WHERE started_at >= $2 AND id NOT IN (SELECT other_stream_id FROM merged_streams)),
               coalesce(sum(extract(epoch FROM least(coalesce(ended_at, now()), $3) - greatest(started_at, $2))), 0)
        FROM streams
        WHERE channel_id = $1 AND started_at < $3 AND coalesce(ended_at, now()) > $2
          AND id NOT IN (SELECT stream_id FROM excluded_streams)
        """,
        [id, from, to]
      ).rows

    [[chatters]] =
      Repo.query!(
        """
        SELECT count(DISTINCT u.user_id) FROM chat_stream_users u
        JOIN streams s ON s.id = u.stream_id
        WHERE s.channel_id = $1 AND s.started_at >= $2 AND s.started_at < $3
          AND s.id NOT IN (SELECT stream_id FROM excluded_streams)
        """,
        [id, from, to]
      ).rows

    gain = Map.get(follower_gains([id], from, to), id)

    # Follows, subs, gifts and Kicks come by webhook: how much of the
    # period the ingress covered says how complete their sums are, and
    # with no coverage at all they are unknown, not 0.
    ingress = Series.coverage(channel, "ingress", from, to)
    webhook = fn v -> if ingress > 0, do: to_i(v) end

    %{
      hours_watched: hw,
      avg_viewers: num(avg),
      peak_viewers: peak,
      samples: to_i(samples) || 0,
      streams: streams,
      airtime_s: round(num(airtime)),
      follows: webhook.(follows),
      follower_gain: gain.gain,
      follower_gain_since: gain.since,
      subs: webhook.(subs),
      gifted_subs: webhook.(gifts),
      kicks: webhook.(kicks),
      ingress_coverage: ingress,
      messages: to_i(messages),
      unique_chatters: chatters
    }
  end

  @doc """
  Follower gain over `[from, to)` for several channels, in one query:
  `%{channel_id => %{gain: integer | nil, since: DateTime.t() | nil}}`.
  The end is the last reading at or before `to` (or now), within a day.
  The baseline is the last reading at or before `from`, within a day; when
  there is none (the period starts before the first reading, as "all"
  does), it is the first reading in the period, and `since` says when that
  was, so the gain is labeled "since the first reading". nil without both.
  """
  @spec follower_gains([integer()], DateTime.t(), DateTime.t()) :: %{integer() => map()}
  def follower_gains(channel_ids, from, to) do
    to = Enum.min([to, DateTime.utc_now()], DateTime)

    Repo.query!(
      """
      SELECT c.id, a.followers, a.observed_at, a.pref, b.followers, b.observed_at
      FROM unnest($1::bigint[]) AS c(id)
      LEFT JOIN LATERAL (
        SELECT followers, observed_at, pref FROM (
          (SELECT followers, observed_at, 0 AS pref FROM follower_samples
           WHERE channel_id = c.id AND observed_at <= $2 AND observed_at > $2::timestamptz - interval '1 day'
           ORDER BY observed_at DESC LIMIT 1)
          UNION ALL
          (SELECT followers, observed_at, 1 AS pref FROM follower_samples
           WHERE channel_id = c.id AND observed_at > $2 AND observed_at < $3
           ORDER BY observed_at LIMIT 1)
        ) x ORDER BY pref LIMIT 1
      ) a ON true
      LEFT JOIN LATERAL (
        SELECT followers, observed_at FROM follower_samples
        WHERE channel_id = c.id AND observed_at <= $3 AND observed_at > $3::timestamptz - interval '1 day'
        ORDER BY observed_at DESC LIMIT 1
      ) b ON true
      """,
      [channel_ids, from, to]
    ).rows
    |> Map.new(fn [id, a, a_at, pref, b, b_at] ->
      gain =
        cond do
          is_nil(a) or is_nil(b) -> nil
          pref == 1 and DateTime.compare(b_at, a_at) != :gt -> nil
          true -> b - a
        end

      {id, %{gain: gain, since: if(gain && pref == 1, do: a_at)}}
    end)
  end

  @doc "When tracking of the earliest public channel began (nil without channels)."
  @spec earliest_tracked_since() :: DateTime.t() | nil
  def earliest_tracked_since do
    Repo.one(from c in Channel, where: c.public, select: min(c.tracked_since))
  end

  ## Streams

  @doc """
  A channel's streams, newest first, with their figures and main category
  (the one most of its samples carry). Excluded streams are marked.
  """
  @spec streams(Channel.t(), keyword()) :: [map()]
  def streams(%Channel{id: id}, opts \\ []) do
    from = opts[:from] || ~U[2000-01-01 00:00:00Z]
    to = opts[:to] || DateTime.add(DateTime.utc_now(), 1, :day)
    limit = opts[:limit] || 500

    Repo.query!(
      """
      SELECT s.id, s.started_at,
             CASE WHEN s.ended_at IS NULL OR mg.open THEN NULL ELSE greatest(s.ended_at, mg.last_end) END,
             st.airtime_s, st.avg_viewers, st.peak_viewers,
             st.hours_watched, st.follower_gain, st.unique_chatters, st.messages, st.follows,
             st.subs, st.resubs, st.gifted_subs, st.kicks, cat.id, cat.name,
             (s.id IN (SELECT stream_id FROM excluded_streams))
      FROM streams s
      LEFT JOIN stream_stats st ON st.stream_id = s.id
      LEFT JOIN LATERAL (
        SELECT max(os.ended_at) AS last_end, bool_or(os.ended_at IS NULL) AS open
        FROM merge_groups g JOIN streams os ON os.id = g.stream_id WHERE g.root_id = s.id
      ) mg ON true
      LEFT JOIN LATERAL (
        SELECT category_id FROM viewer_samples
        WHERE channel_id = s.channel_id AND stream_id = s.id
        GROUP BY category_id ORDER BY count(*) DESC LIMIT 1
      ) mc ON true
      LEFT JOIN categories cat ON cat.id = mc.category_id
      WHERE s.channel_id = $1 AND s.started_at >= $2 AND s.started_at < $3
        AND s.id NOT IN (SELECT other_stream_id FROM merged_streams)
        AND ($5::bigint IS NULL OR mc.category_id = $5)
      ORDER BY s.started_at DESC
      LIMIT $4
      """,
      [id, from, to, limit, opts[:category_id]]
    ).rows
    |> Enum.map(fn [
                     sid,
                     started,
                     ended,
                     air,
                     avg,
                     peak,
                     hw,
                     gain,
                     chatters,
                     msgs,
                     follows,
                     subs,
                     resubs,
                     gifts,
                     kicks,
                     cid,
                     cname,
                     excluded
                   ] ->
      %{
        id: sid,
        started_at: started,
        ended_at: ended,
        airtime_s: air || Metrics.airtime_s(started, ended || DateTime.utc_now()),
        avg_viewers: avg,
        peak_viewers: peak,
        hours_watched: hw,
        follower_gain: gain,
        unique_chatters: chatters,
        messages: msgs,
        follows: follows,
        subs: subs,
        resubs: resubs,
        gifted_subs: gifts,
        kicks: kicks,
        category_id: cid,
        category: cname,
        excluded?: excluded
      }
    end)
  end

  @doc """
  One stream with its figures, or nil. A stream merged into another says
  so (`merged_into`); one others were merged into ends with the last of
  them (`stream_ids` lists them all).
  """
  @spec stream(integer()) :: map() | nil
  def stream(id) do
    case Repo.query!(
           "SELECT channel_id, started_at, ended_at, end_source FROM streams WHERE id = $1",
           [id]
         ).rows do
      [[channel_id, started, ended, source]] ->
        stats =
          Repo.one(
            from st in "stream_stats",
              where: st.stream_id == ^id,
              select: %{
                airtime_s: st.airtime_s,
                avg_viewers: st.avg_viewers,
                peak_viewers: st.peak_viewers,
                hours_watched: st.hours_watched,
                followers_start: st.followers_start,
                followers_end: st.followers_end,
                follower_gain: st.follower_gain,
                follows: st.follows,
                unique_chatters: st.unique_chatters,
                messages: st.messages,
                subs: st.subs,
                resubs: st.resubs,
                gifted_subs: st.gifted_subs,
                kicks: st.kicks
              }
          )

        # Merges resolve to the root of the group (`merge_groups`), at any depth.
        [[excluded, merged_into]] =
          Repo.query!(
            "SELECT $1 IN (SELECT stream_id FROM excluded_streams), (SELECT root_id FROM merge_groups WHERE stream_id = $1 LIMIT 1)",
            [id]
          ).rows

        merged =
          Repo.query!(
            "SELECT s.id, s.ended_at FROM merge_groups g JOIN streams s ON s.id = g.stream_id WHERE g.root_id = $1 ORDER BY s.started_at",
            [id]
          ).rows

        ends = [ended | Enum.map(merged, &List.last/1)]

        %{
          id: id,
          stream_ids: [id | Enum.map(merged, &hd/1)],
          channel_id: channel_id,
          started_at: started,
          ended_at: if(Enum.any?(ends, &is_nil/1), do: nil, else: Enum.max(ends, DateTime)),
          end_source: source,
          stats: stats,
          excluded?: excluded,
          merged_into: merged_into
        }

      [] ->
        nil
    end
  end

  @doc """
  A stream's title and category history: `%{segments: [...], titles: [...]}`,
  where a segment is a stretch of one category (`from`, `to` as unix
  seconds, `name`) and titles are the title changes.
  """
  @spec timeline(map()) :: %{segments: [map()], titles: [map()]}
  def timeline(stream) do
    until = stream.ended_at || DateTime.utc_now()

    changes =
      Repo.query!(
        """
        SELECT sc.field, sc.occurred_at, sc.new_value, cat.name
        FROM stream_changes sc
        LEFT JOIN categories cat ON sc.field = 'category' AND cat.id::text = sc.new_value
        WHERE sc.stream_id = ANY($1) AND sc.field IN ('title', 'category')
        ORDER BY sc.occurred_at
        """,
        [Map.get(stream, :stream_ids, [stream.id])]
      ).rows

    categories = for [f, at, v, name] <- changes, f == "category", do: {at, name || v}

    segments =
      categories
      |> Enum.zip(tl(categories ++ [{until, nil}]))
      |> Enum.map(fn {{at, name}, {next, _}} ->
        %{
          from: DateTime.to_unix(clamp(at, stream.started_at)),
          to: DateTime.to_unix(next),
          name: name
        }
      end)

    titles = for [f, at, v, _] <- changes, f == "title", do: %{at: DateTime.to_unix(at), title: v}
    %{segments: segments, titles: titles}
  end

  defp clamp(at, min), do: Enum.max([at, min], DateTime)

  @doc """
  Moments worth a marker on a stream's chart: gift bursts (10 or more subs
  at once), big Kicks (250 or more), raids and hosts.
  """
  @spec markers(map()) :: [map()]
  def markers(stream) do
    until = stream.ended_at || DateTime.utc_now()

    support =
      Repo.query!(
        """
        SELECT kind, occurred_at, quantity FROM support_events
        WHERE channel_id = $1 AND occurred_at >= $2 AND occurred_at <= $3
          AND ((kind = 'gift' AND quantity >= 10) OR (kind = 'kicks' AND quantity >= 250))
        ORDER BY occurred_at
        """,
        [stream.channel_id, stream.started_at, until]
      ).rows
      |> Enum.map(fn [kind, at, q] -> %{kind: kind, at: DateTime.to_unix(at), value: q} end)

    raids =
      Repo.query!(
        """
        SELECT kind, occurred_at, viewers, other_channel FROM channel_events
        WHERE channel_id = $1 AND occurred_at >= $2 AND occurred_at <= $3 ORDER BY occurred_at
        """,
        [stream.channel_id, stream.started_at, until]
      ).rows
      |> Enum.map(fn [kind, at, v, other] ->
        %{kind: kind, at: DateTime.to_unix(at), value: v, other: other}
      end)

    # The biggest few, so a busy stream's chart stays readable.
    support =
      support
      |> Enum.sort_by(&(-&1.value))
      |> Enum.take(@max_markers)
      |> Enum.sort_by(& &1.at)

    flags =
      Repo.query!(
        """
        SELECT f.reason, f.observed_at, v.viewers FROM viewer_flags f
        JOIN viewer_samples v ON v.channel_id = f.channel_id AND v.observed_at = f.observed_at
        WHERE f.stream_id = ANY($1)
        ORDER BY f.observed_at
        """,
        [Map.get(stream, :stream_ids, [stream.id])]
      ).rows
      |> Enum.map(fn [reason, at, v] ->
        %{kind: "flagged", reason: reason, at: DateTime.to_unix(at), value: v}
      end)

    support ++ raids ++ flags
  end

  @doc "The stream's top chatters and supporters, by name where we know it."
  @spec top_people(map(), pos_integer()) :: %{chatters: [map()], supporters: [map()]}
  def top_people(stream, limit \\ 10) do
    until = stream.ended_at || DateTime.utc_now()

    chatters =
      Repo.query!(
        """
        SELECT u.user_id, k.username, u.messages FROM chat_stream_users u
        LEFT JOIN kick_users k ON k.id = u.user_id
        WHERE u.stream_id = ANY($1) ORDER BY u.messages DESC, u.user_id LIMIT $2
        """,
        [Map.get(stream, :stream_ids, [stream.id]), limit]
      ).rows
      |> Enum.map(fn [id, name, n] -> %{user_id: id, name: name, count: n} end)

    supporters =
      Repo.query!(
        """
        SELECT e.user_id, k.username,
               coalesce(sum(e.quantity) FILTER (WHERE e.kind = 'gift'), 0)::int AS gifts,
               coalesce(sum(e.quantity) FILTER (WHERE e.kind = 'kicks'), 0)::int AS kicks,
               count(*) FILTER (WHERE e.kind IN ('sub', 'resub'))::int AS subs
        FROM support_events e LEFT JOIN kick_users k ON k.id = e.user_id
        WHERE e.channel_id = $1 AND e.occurred_at >= $2 AND e.occurred_at <= $3 AND e.user_id IS NOT NULL
        GROUP BY 1, 2 ORDER BY gifts DESC, kicks DESC, subs DESC LIMIT $4
        """,
        [stream.channel_id, stream.started_at, until, limit]
      ).rows
      |> Enum.map(fn [id, name, g, k, s] ->
        %{user_id: id, name: name, gifts: g, kicks: k, subs: s}
      end)

    %{chatters: chatters, supporters: supporters}
  end

  ## Chat and support pages

  @doc """
  Per stream in a period: unique chatters, how many chatted in this
  channel for the first time (since tracking began), and the others.
  """
  @spec chatter_retention(Channel.t(), DateTime.t(), DateTime.t()) :: [map()]
  def chatter_retention(%Channel{id: id}, from, to) do
    Repo.query!(
      """
      SELECT s.id, s.started_at, st.unique_chatters, st.new_chatters
      FROM streams s JOIN stream_stats st ON st.stream_id = s.id
      WHERE s.channel_id = $1 AND s.started_at >= $2 AND s.started_at < $3
        AND s.id NOT IN (SELECT other_stream_id FROM merged_streams)
        AND s.id NOT IN (SELECT stream_id FROM excluded_streams)
      ORDER BY s.started_at
      """,
      [id, from, to]
    ).rows
    |> Enum.map(fn [sid, at, n, new] ->
      %{stream_id: sid, started_at: at, chatters: n, new: new, returning: new && n - new}
    end)
  end

  @doc """
  Support over a period: totals, the top gifters and Kick senders, and a
  revenue estimate from the admin's assumptions (always labeled, §13.1).
  """
  @spec support_summary(Channel.t(), DateTime.t(), DateTime.t()) :: map()
  def support_summary(%Channel{id: id}, from, to) do
    [[subs, resubs, gifts, kicks]] =
      Repo.query!(
        """
        SELECT count(*) FILTER (WHERE kind = 'sub')::int, count(*) FILTER (WHERE kind = 'resub')::int,
               coalesce(sum(quantity) FILTER (WHERE kind = 'gift'), 0)::int,
               coalesce(sum(quantity) FILTER (WHERE kind = 'kicks'), 0)::int
        FROM support_events WHERE channel_id = $1 AND occurred_at >= $2 AND occurred_at < $3
        """,
        [id, from, to]
      ).rows

    top = fn kind ->
      Repo.query!(
        """
        SELECT e.user_id, k.username, sum(e.quantity)::int, count(*)::int
        FROM support_events e LEFT JOIN kick_users k ON k.id = e.user_id
        WHERE e.channel_id = $1 AND e.kind = $4 AND e.occurred_at >= $2 AND e.occurred_at < $3
          AND e.user_id IS NOT NULL
        GROUP BY 1, 2 ORDER BY 3 DESC, 1 LIMIT 10
        """,
        [id, from, to, kind]
      ).rows
      |> Enum.map(fn [uid, name, total, times] ->
        %{user_id: uid, name: name, total: total, times: times}
      end)
    end

    s = KickTracker.Settings.all()
    paid_subs = subs + resubs + gifts
    revenue = paid_subs * s["sub_price_usd"] * s["sub_share"] + kicks * s["kick_value_usd"]

    %{
      subs: subs,
      resubs: resubs,
      gifted_subs: gifts,
      kicks: kicks,
      top_gifters: top.("gift"),
      top_kicks: top.("kicks"),
      estimated_revenue_usd: revenue,
      assumptions: Map.take(s, ~w(sub_price_usd sub_share kick_value_usd))
    }
  end

  ## Heatmap and categories

  @doc """
  Average viewers by weekday and hour in the channel's timezone: a 7 × 24
  matrix (Monday first), `nil` where the channel was never live.
  """
  @spec heatmap(Channel.t(), DateTime.t(), DateTime.t()) :: [[number() | nil]]
  def heatmap(%Channel{} = channel, from, to) do
    cells =
      Repo.query!(
        """
        SELECT extract(isodow FROM hour AT TIME ZONE $4)::int, extract(hour FROM hour AT TIME ZONE $4)::int,
               round(sum(avg_viewers * samples) / sum(samples))::int
        FROM hourly_stats WHERE channel_id = $1 AND hour >= $2 AND hour < $3 AND samples > 0
        GROUP BY 1, 2
        """,
        [channel.id, from, to, channel.timezone]
      ).rows
      |> Map.new(fn [d, h, v] -> {{d, h}, v} end)

    for d <- 1..7, do: for(h <- 0..23, do: cells[{d, h}])
  end

  @doc """
  Per category over a period: hours watched, airtime, average viewers,
  and the average change in viewers after switching to it (the 15 minutes
  after the switch against the 15 before).
  """
  @spec categories(Channel.t(), DateTime.t(), DateTime.t()) :: [map()]
  def categories(%Channel{} = channel, from, to) do
    shares =
      Repo.query!(
        """
        WITH weighted AS (
          SELECT v.category_id, v.viewers, v.observed_at,
                 LEAST(EXTRACT(EPOCH FROM v.observed_at - coalesce(
                   lag(v.observed_at) OVER (PARTITION BY v.stream_id ORDER BY v.observed_at), s.started_at)), $4) AS w
          FROM viewer_samples v JOIN streams s ON s.id = v.stream_id
          -- one cap before the range, so the first sample in it is weighted
          -- from its real previous one, as in hourly_stats
          WHERE v.channel_id = $1 AND v.observed_at >= $2::timestamptz - make_interval(secs => $4::int)
            AND v.observed_at < $3
            AND v.stream_id NOT IN (SELECT stream_id FROM excluded_streams)
        )
        SELECT category_id, (sum(viewers * greatest(w, 0)) / 3600)::float, sum(greatest(w, 0))::float,
               avg(viewers)::float
        FROM weighted WHERE observed_at >= $2 GROUP BY 1 ORDER BY 2 DESC
        """,
        [channel.id, from, to, Metrics.cap_s()]
      ).rows

    switches =
      Repo.query!(
        """
        SELECT sc.new_value::bigint,
               avg((SELECT avg(viewers) FROM viewer_samples v WHERE v.channel_id = s.channel_id
                    AND v.observed_at > sc.occurred_at AND v.observed_at <= sc.occurred_at + interval '15 minutes')
                 - (SELECT avg(viewers) FROM viewer_samples v WHERE v.channel_id = s.channel_id
                    AND v.observed_at > sc.occurred_at - interval '15 minutes' AND v.observed_at <= sc.occurred_at))::float,
               count(*)
        FROM stream_changes sc JOIN streams s ON s.id = sc.stream_id
        WHERE s.channel_id = $1 AND sc.field = 'category' AND sc.old_value IS NOT NULL
          AND sc.occurred_at >= $2 AND sc.occurred_at < $3 AND sc.new_value ~ '^[0-9]+$'
        GROUP BY 1
        """,
        [channel.id, from, to]
      ).rows
      |> Map.new(fn [cid, change, n] -> {cid, {change, n}} end)

    names = category_names(Enum.map(shares, &hd/1))
    total = shares |> Enum.map(&Enum.at(&1, 1)) |> Enum.sum()

    Enum.map(shares, fn [cid, hw, air, avg] ->
      {change, n} = Map.get(switches, cid, {nil, 0})

      %{
        category_id: cid,
        name: names[cid] || (cid && "##{cid}") || "–",
        hours_watched: hw,
        share: if(total > 0, do: hw / total),
        airtime_s: round(air),
        avg_viewers: avg,
        switch_change: change,
        switches: n
      }
    end)
  end

  defp category_names(ids) do
    ids = Enum.reject(ids, &is_nil/1)
    Repo.all(from c in "categories", where: c.id in ^ids, select: {c.id, c.name}) |> Map.new()
  end

  @doc """
  All categories seen, with a URL slug. Two names with the same slug
  ("Just Chatting" and "just-chatting") are told apart: the category seen
  first (lowest id) keeps the plain slug, the others get their id appended.
  """
  @spec all_categories() :: [map()]
  def all_categories do
    categories =
      Repo.all(from c in "categories", order_by: c.id, select: %{id: c.id, name: c.name})
      |> Enum.map(&Map.put(&1, :slug, slugify(&1.name)))

    {categories, _} =
      Enum.map_reduce(categories, MapSet.new(), fn c, taken ->
        if MapSet.member?(taken, c.slug),
          do: {%{c | slug: "#{c.slug}-#{c.id}"}, taken},
          else: {c, MapSet.put(taken, c.slug)}
      end)

    Enum.sort_by(categories, &{&1.name, &1.id})
  end

  @doc "A category by its URL slug, ignoring case; nil when none has it."
  @spec category_by_slug(String.t()) :: map() | nil
  def category_by_slug(slug) do
    slug = String.downcase(slug)
    Enum.find(all_categories(), &(&1.slug == slug))
  end

  @doc """
  A URL slug for a name: lowercase letters and digits of any script,
  accents dropped, anything else a dash. A name with no letter or digit
  at all gets a short, stable one derived from it.

      iex> KickTracker.Reports.slugify("Pokémon Go")
      "pokemon-go"
      iex> KickTracker.Reports.slugify("Игры")
      "игры"
      iex> KickTracker.Reports.slugify("🎮")
      "c-5928d14b"
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    slug =
      name
      |> String.normalize(:nfd)
      # Accents off Latin letters only: in other scripts the marks are
      # part of the letter (ゲ is not ケ).
      |> String.replace(~r/(\p{Latin})\p{Mn}+/u, "\\1")
      |> String.normalize(:nfc)
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")

    if slug == "",
      do:
        "c-" <> (:crypto.hash(:sha256, name) |> binary_part(0, 4) |> Base.encode16(case: :lower)),
      else: slug
  end

  @doc "Tracked channels in a category over a period, by hours watched."
  @spec category_channels(integer(), DateTime.t(), DateTime.t()) :: [map()]
  def category_channels(category_id, from, to) do
    Repo.query!(
      """
      WITH chans AS (
        SELECT DISTINCT channel_id FROM viewer_samples
        WHERE category_id = $1 AND observed_at >= $2 AND observed_at < $3
      ),
      -- Every sample of those channels, whatever its category, so each is
      -- weighted from its real previous one (also from one cap before the
      -- range), as in hourly_stats.
      weighted AS (
        SELECT v.channel_id, v.category_id, v.viewers, v.observed_at,
               EXISTS (SELECT 1 FROM viewer_flags f
                       WHERE f.channel_id = v.channel_id AND f.observed_at = v.observed_at) AS flagged,
               LEAST(EXTRACT(EPOCH FROM v.observed_at - coalesce(
                 lag(v.observed_at) OVER (PARTITION BY v.stream_id ORDER BY v.observed_at), s.started_at)), $4) AS w
        FROM viewer_samples v JOIN streams s ON s.id = v.stream_id
        WHERE v.channel_id IN (SELECT channel_id FROM chans)
          AND v.observed_at >= $2::timestamptz - make_interval(secs => $4::int) AND v.observed_at < $3
          AND v.stream_id NOT IN (SELECT stream_id FROM excluded_streams)
      )
      SELECT c.id, c.slug, (sum(w.viewers * greatest(w.w, 0)) / 3600)::float, sum(greatest(w.w, 0))::float,
             avg(w.viewers)::float,
             -- a flagged reading (a glitch) is never a peak (§19.2)
             max(w.viewers) FILTER (WHERE NOT w.flagged)
      FROM weighted w JOIN channels c ON c.id = w.channel_id AND c.public
      WHERE w.category_id = $1 AND w.observed_at >= $2
      GROUP BY 1, 2 ORDER BY 3 DESC
      """,
      [category_id, from, to, Metrics.cap_s()]
    ).rows
    |> Enum.map(fn [id, slug, hw, air, avg, peak] ->
      %{
        channel_id: id,
        slug: slug,
        hours_watched: hw,
        airtime_s: round(air),
        avg_viewers: avg,
        peak_viewers: peak
      }
    end)
  end

  ## Leaderboards, records, overlap

  @leaderboard_metrics ~w(hours_watched avg_viewers peak_viewers follower_gain kicks)

  @doc "The metrics a leaderboard can rank by."
  def leaderboard_metrics, do: @leaderboard_metrics

  @doc """
  Channels ranked over a period (all tracked channels, or those given).
  Channels with no figure for the metric come last.
  """
  @spec leaderboard(DateTime.t(), DateTime.t(), String.t(), [integer()] | nil) :: [map()]
  def leaderboard(from, to, metric, channel_ids \\ nil) when metric in @leaderboard_metrics do
    rows =
      Repo.query!(
        """
        SELECT c.id, c.slug, sum(h.hours_watched), sum(h.avg_viewers * h.samples) / nullif(sum(h.samples), 0),
               max(h.peak_viewers), sum(h.kicks), sum(h.samples)
        FROM channels c
        LEFT JOIN hourly_stats h ON h.channel_id = c.id AND h.hour >= $1 AND h.hour < $2
        WHERE c.public AND ($3::bigint[] IS NULL OR c.id = ANY($3))
        GROUP BY c.id, c.slug
        """,
        [from, to, channel_ids]
      ).rows
      |> Enum.map(fn [id, slug, hw, avg, peak, kicks, samples] ->
        %{
          channel_id: id,
          slug: slug,
          hours_watched: hw,
          avg_viewers: num(avg),
          peak_viewers: peak,
          kicks: to_i(kicks),
          samples: to_i(samples) || 0
        }
      end)

    rows =
      if metric == "follower_gain" do
        gains = follower_gains(Enum.map(rows, & &1.channel_id), from, to)

        Enum.map(rows, fn r ->
          gain = Map.get(gains, r.channel_id, %{gain: nil, since: nil})
          Map.merge(r, %{follower_gain: gain.gain, follower_gain_since: gain.since})
        end)
      else
        rows
      end

    key = String.to_existing_atom(metric)

    rows
    |> Enum.sort_by(&{is_nil(&1[key]), -(&1[key] || 0)})
  end

  @doc "A channel's lifetime records: highest peak, most hours watched in a stream, longest stream."
  @spec records(Channel.t()) :: map()
  # sobelow_skip ["SQL.Query"]
  def records(%Channel{id: id}) do
    best = fn order ->
      case Repo.query!(
             """
             SELECT s.id, s.started_at, st.peak_viewers, st.hours_watched, st.airtime_s
             FROM stream_stats st JOIN streams s ON s.id = st.stream_id
             WHERE st.channel_id = $1 AND s.id NOT IN (SELECT stream_id FROM excluded_streams)
               AND s.id NOT IN (SELECT other_stream_id FROM merged_streams)
               AND st.#{order} IS NOT NULL
             ORDER BY st.#{order} DESC LIMIT 1
             """,
             [id]
           ).rows do
        [[sid, at, peak, hw, air]] ->
          %{stream_id: sid, started_at: at, peak_viewers: peak, hours_watched: hw, airtime_s: air}

        [] ->
          nil
      end
    end

    %{
      peak: best.("peak_viewers"),
      hours_watched: best.("hours_watched"),
      longest: best.("airtime_s")
    }
  end

  @doc """
  Notable moments over a period, across channels: new peak records
  (streams whose peak beat everything before them), the biggest gift
  bursts, and raids.
  """
  @spec notable(DateTime.t(), DateTime.t(), pos_integer()) :: [map()]
  def notable(from, to, limit \\ 8) do
    # One pass over each channel's streams in order: the best peak before
    # each (excluded streams don't count) is a running max, not a query
    # per stream.
    records =
      Repo.query!(
        """
        WITH ordered AS (
          SELECT c.slug, s.id, s.started_at, st.peak_viewers,
                 e.stream_id IS NOT NULL AS excluded,
                 max(st.peak_viewers) FILTER (WHERE e.stream_id IS NULL) OVER earlier AS best_before,
                 count(*) OVER earlier AS older
          FROM streams s
          JOIN channels c ON c.id = s.channel_id AND c.public
          LEFT JOIN stream_stats st ON st.stream_id = s.id
          LEFT JOIN excluded_streams e ON e.stream_id = s.id
          WHERE s.started_at < $2
          WINDOW earlier AS (PARTITION BY s.channel_id ORDER BY s.started_at
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        )
        SELECT slug, id, started_at, peak_viewers FROM ordered
        WHERE started_at >= $1 AND peak_viewers IS NOT NULL AND NOT excluded AND older > 0
          AND id NOT IN (SELECT other_stream_id FROM merged_streams)
          AND peak_viewers > coalesce(best_before, 0)
        ORDER BY peak_viewers DESC LIMIT $3
        """,
        [from, to, limit]
      ).rows
      |> Enum.map(fn [slug, sid, at, peak] ->
        %{kind: "record", slug: slug, stream_id: sid, at: at, value: peak}
      end)

    gifts =
      Repo.query!(
        """
        SELECT c.slug, e.occurred_at, e.quantity, k.username,
               (SELECT id FROM streams s WHERE s.channel_id = e.channel_id AND s.started_at <= e.occurred_at
                  AND coalesce(s.ended_at, now()) >= e.occurred_at LIMIT 1)
        FROM support_events e JOIN channels c ON c.id = e.channel_id AND c.public
        LEFT JOIN kick_users k ON k.id = e.user_id
        WHERE e.kind = 'gift' AND e.occurred_at >= $1 AND e.occurred_at < $2 AND e.quantity >= 10
        ORDER BY e.quantity DESC, e.occurred_at DESC LIMIT $3
        """,
        [from, to, limit]
      ).rows
      |> Enum.map(fn [slug, at, q, who, sid] ->
        %{kind: "gifts", slug: slug, at: at, value: q, who: who, stream_id: sid}
      end)

    raids =
      Repo.query!(
        """
        SELECT c.slug, e.occurred_at, e.viewers, e.other_channel, e.kind FROM channel_events e
        JOIN channels c ON c.id = e.channel_id AND c.public
        WHERE e.occurred_at >= $1 AND e.occurred_at < $2 ORDER BY e.viewers DESC NULLS LAST LIMIT $3
        """,
        [from, to, limit]
      ).rows
      |> Enum.map(fn [slug, at, v, other, kind] ->
        %{kind: kind, slug: slug, at: at, value: v, other: other}
      end)

    (records ++ gifts ++ raids) |> Enum.sort_by(& &1.at, {:desc, DateTime}) |> Enum.take(limit)
  end

  @doc """
  Unique chatters of each channel over a period and how many they share,
  pairwise: `%{counts: %{id => n}, pairs: %{{a, b} => shared}}`.
  """
  @spec overlap([integer()], DateTime.t(), DateTime.t()) :: map()
  def overlap(channel_ids, from, to) do
    rows =
      Repo.query!(
        """
        WITH people AS (
          SELECT DISTINCT s.channel_id, u.user_id FROM chat_stream_users u
          JOIN streams s ON s.id = u.stream_id
          WHERE s.channel_id = ANY($1) AND s.started_at >= $2 AND s.started_at < $3
            AND s.id NOT IN (SELECT stream_id FROM excluded_streams)
        )
        SELECT a.channel_id, b.channel_id, count(*) FROM people a
        JOIN people b ON a.user_id = b.user_id AND a.channel_id <= b.channel_id
        GROUP BY 1, 2
        """,
        [channel_ids, from, to]
      ).rows

    counts = for [a, a, n] <- rows, into: %{}, do: {a, n}
    pairs = for [a, b, n] <- rows, a != b, into: %{}, do: {{a, b}, n}
    %{counts: counts, pairs: pairs}
  end

  defp num(nil), do: nil
  defp num(%Decimal{} = d), do: Decimal.to_float(d)
  defp num(n), do: n

  defp to_i(nil), do: nil
  defp to_i(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_i(n) when is_float(n), do: round(n)
  defp to_i(n), do: n
end
