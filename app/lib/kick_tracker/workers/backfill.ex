defmodule KickTracker.Workers.Backfill do
  @moduledoc """
  Fills our gaps from the shadow collector (project.md §10.5), every 5
  minutes on the collecting node, when `SHADOW_DATABASE_URL` is set.

  For each channel and source (`api`, `subscribers`, `followers`, `chat`)
  over the last `BACKFILL_DAYS`, `Collector.BackfillPlan` finds the ranges
  the shadow covered and we didn't (a VPS outage, both our collectors
  down), and the shadow's rows for those ranges are applied here as
  `Collector.Ops`: upserts on natural keys, so a row we have always wins
  and running again changes nothing. Chat is filled only for whole
  minutes we have nothing for, so no minute is counted twice. Each filled
  range is recorded in `coverage` with `collector = 'shadow'`, which also
  stops it being filled again; the rollups are rebuilt over it.

  Only what the shadow observes is filled: viewers and streams (from
  polls), subscriber and follower totals, chat. Webhook events are the
  receivers' (a backup receiver spools them, §15.2). Removed channels and
  users stay removed. The shadow's own state is recorded as the
  `collector_nodes` row `shadow`, for the health page and the alerts.
  """

  use Oban.Worker, queue: :kick, max_attempts: 1, unique: [period: 240]

  require Logger

  alias KickTracker.{Collector, Repo}
  alias KickTracker.Collector.{BackfillPlan, Ops, Remote}
  alias KickTracker.Workers.Reprocess

  # source => {pad (one cadence), smallest range worth filling}, in seconds.
  @sources %{
    "api" => {60, 60},
    "chat" => {60, 60},
    "subscribers" => {300, 300},
    "followers" => {900, 900}
  }
  # Leave the last two minutes to the collectors: they are still writing.
  @settle_s 120

  @impl Oban.Worker
  def perform(_job) do
    case Collector.config(:shadow_database_url) do
      nil ->
        :ok

      url ->
        case Remote.with_conn(url, &run/1) do
          {:ok, summary} ->
            if summary.filled > 0,
              do: Logger.info("backfill: #{summary.filled} range(s) filled from the shadow")

            :ok

          {:error, reason} ->
            Logger.warning("backfill: the shadow can't be read: #{inspect(reason, limit: 5)}")
            :ok
        end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc false
  # Public for tests: one pass with a query function on the shadow's database.
  # (Our own queries go through the same shape of function; all are fixed text.)
  # sobelow_skip ["SQL.Query"]
  def run(shadow) do
    [[now]] = Repo.query!("SELECT now()").rows

    window =
      {DateTime.add(now, -Collector.config(:backfill_days, 7), :day),
       DateTime.add(now, -@settle_s)}

    ids = channel_map(shadow)
    ours = periods(fn sql, params -> Repo.query!(sql, params).rows end, window)
    theirs = periods(shadow, window)
    removed = removed_users()

    filled =
      for {shadow_id, main_id} <- ids,
          {source, {pad, min}} <- @sources,
          range <-
            BackfillPlan.fill(
              window,
              Map.get(ours, {main_id, source}, []),
              Map.get(theirs, {shadow_id, source}, []),
              pad,
              min
            ) do
        copy(shadow, source, shadow_id, main_id, range, removed)
        record_coverage(main_id, source, range, pad)
        range
      end

    if filled != [] do
      from = filled |> Enum.map(&elem(&1, 0)) |> Enum.min(DateTime)
      to = filled |> Enum.map(&elem(&1, 1)) |> Enum.max(DateTime)

      {:ok, _} =
        Reprocess.enqueue(%{
          "kind" => "rollups",
          "from" => DateTime.to_iso8601(from),
          "to" => DateTime.to_iso8601(to)
        })
    end

    record_shadow(shadow, length(filled))
    %{filled: length(filled)}
  end

  # The shadow's channel ids mapped to ours, by Kick id; channels we don't
  # have (or removed) are left out.
  defp channel_map(shadow) do
    ours = Repo.query!("SELECT kick_user_id, id FROM channels").rows |> Map.new(&List.to_tuple/1)

    for [shadow_id, kick_user_id] <- shadow.("SELECT id, kick_user_id FROM channels", []),
        main_id = ours[kick_user_id],
        main_id != nil,
        into: %{},
        do: {shadow_id, main_id}
  end

  # Working coverage periods overlapping the window, by {channel, source}.
  defp periods(query, {from, to}) do
    query.(
      "SELECT channel_id, source, from_at, to_at FROM coverage WHERE ok AND channel_id IS NOT NULL AND to_at >= $1 AND from_at <= $2",
      [DateTime.add(from, -3600), to]
    )
    |> Enum.group_by(fn [c, s, _, _] -> {c, s} end, fn [_, _, a, b] -> {a, b} end)
  end

  defp removed_users do
    Repo.query!("SELECT kick_user_id FROM removals WHERE kind = 'user'").rows
    |> List.flatten()
    |> MapSet.new()
  end

  # --- copying one range -------------------------------------------------------

  defp copy(shadow, "api", shadow_id, main_id, {from, to}, _removed) do
    streams =
      shadow.(
        "SELECT started_at, ended_at, end_source FROM streams WHERE channel_id = $1 AND started_at < $3 AND (ended_at IS NULL OR ended_at >= $2)",
        [shadow_id, from, to]
      )

    stream_ops =
      for [started_at, ended_at, end_source] <- streams,
          op <- [
            {:stream, main_id, {:open, started_at}}
            | if(ended_at,
                do: [{:stream, main_id, {:close, started_at, ended_at, end_source(end_source)}}],
                else: []
              )
          ],
          do: op

    samples =
      shadow.(
        """
        SELECT v.observed_at, v.viewers, v.category_id, s.started_at
        FROM viewer_samples v JOIN streams s ON s.id = v.stream_id
        WHERE v.channel_id = $1 AND v.observed_at >= $2 AND v.observed_at < $3
        """,
        [shadow_id, from, to]
      )

    category_ids = samples |> Enum.map(&Enum.at(&1, 2)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    category_ops =
      for [id, name, first_seen_at] <-
            shadow.("SELECT id, name, first_seen_at FROM categories WHERE id = ANY($1)", [
              category_ids
            ]),
          do: {:category, %{id: id, name: name}, first_seen_at}

    sample_ops =
      for [at, viewers, category_id, started_at] <- samples,
          do: {:viewer_sample, main_id, started_at, at, viewers, category_id}

    change_ops =
      shadow.(
        """
        SELECT s.started_at, c.occurred_at, c.field, c.old_value, c.new_value, c.source
        FROM stream_changes c JOIN streams s ON s.id = c.stream_id
        WHERE s.channel_id = $1 AND c.occurred_at >= $2 AND c.occurred_at < $3
        ORDER BY c.occurred_at
        """,
        [shadow_id, from, to]
      )
      |> Enum.group_by(&hd/1, fn [_, at, field, old, new, source] ->
        %{
          occurred_at: at,
          field: field,
          old_value: old,
          new_value: new,
          source: end_source(source)
        }
      end)
      |> Enum.map(fn {started_at, changes} -> {:changes, main_id, started_at, changes} end)

    apply_ops(stream_ops ++ category_ops ++ sample_ops ++ change_ops)
  end

  defp copy(shadow, "subscribers", shadow_id, main_id, {from, to}, _removed) do
    rows =
      for [at, active, gifted, canceled] <-
            shadow.(
              "SELECT observed_at, active, active_gifted, canceled FROM subscriber_samples WHERE channel_id = $1 AND observed_at >= $2 AND observed_at < $3",
              [shadow_id, from, to]
            ),
          do: %{
            channel_id: main_id,
            observed_at: at,
            active: active,
            active_gifted: gifted,
            canceled: canceled
          }

    apply_ops(if rows == [], do: [], else: [{:subscriber_samples, rows}])
  end

  defp copy(shadow, "followers", shadow_id, main_id, {from, to}, _removed) do
    shadow.(
      "SELECT observed_at, followers FROM follower_samples WHERE channel_id = $1 AND observed_at >= $2 AND observed_at < $3",
      [shadow_id, from, to]
    )
    |> Enum.map(fn [at, followers] -> {:follower_sample, main_id, at, followers} end)
    |> apply_ops()
  end

  # Whole minutes only, and only minutes we have nothing for.
  defp copy(shadow, "chat", shadow_id, main_id, {from, to}, removed) do
    have =
      Repo.query!(
        "SELECT minute FROM chat_minutes WHERE channel_id = $1 AND minute >= $2 AND minute < $3",
        [main_id, from, to]
      ).rows
      |> List.flatten()
      |> MapSet.new(&DateTime.to_unix/1)

    minutes =
      shadow.(
        """
        SELECT m.minute, s.started_at FROM chat_minutes m LEFT JOIN streams s ON s.id = m.stream_id
        WHERE m.channel_id = $1 AND m.minute >= $2 AND m.minute + interval '1 minute' <= $3
        """,
        [shadow_id, from, to]
      )
      |> Enum.reject(fn [minute, _] -> MapSet.member?(have, DateTime.to_unix(minute)) end)

    if minutes != [] do
      users =
        shadow.(
          "SELECT minute, user_id, messages FROM chat_minute_users WHERE channel_id = $1 AND minute = ANY($2)",
          [shadow_id, Enum.map(minutes, &hd/1)]
        )
        |> Enum.reject(fn [_, user_id, _] -> MapSet.member?(removed, user_id) end)
        |> Enum.group_by(fn [m, _, _] -> DateTime.to_unix(m) end)

      rows =
        for [minute, started_at] <- minutes,
            by_user = users[DateTime.to_unix(minute)],
            by_user != nil do
          last = DateTime.add(minute, 59)

          %{
            minute: minute,
            started_at: started_at,
            users:
              Map.new(by_user, fn [_, user_id, messages] ->
                {user_id, %{messages: messages, first_at: minute, last_at: last}}
              end)
          }
        end

      user_ids = for r <- rows, id <- Map.keys(r.users), uniq: true, do: id

      names =
        for [id, username, seen_at] <-
              shadow.("SELECT id, username, seen_at FROM kick_users WHERE id = ANY($1)", [
                user_ids
              ]),
            do: {id, username, seen_at}

      apply_ops([{:chat, main_id, rows}, {:kick_users, names}])
    end
  end

  defp apply_ops([]), do: :ok

  defp apply_ops(ops) do
    {:ok, _} = Repo.transaction(fn -> Ops.apply_all!(ops) end, timeout: 120_000)
    :ok
  end

  defp end_source(source) when source in ["event", "poll"], do: String.to_existing_atom(source)

  # The range, as the coverage it now has (a period vouches for one
  # cadence past its end, so the end is brought back by that much).
  defp record_coverage(main_id, source, {from, to}, pad) do
    to_at = Enum.max([from, DateTime.add(to, -pad)], DateTime)

    Repo.query!(
      "INSERT INTO coverage (channel_id, source, from_at, to_at, ok, collector) VALUES ($1, $2, $3, $4, true, 'shadow')",
      [main_id, source, from, to_at]
    )
  end

  # The shadow's leading collector, as our row "shadow": stale when the
  # shadow stops collecting or can't be reached.
  defp record_shadow(shadow, filled) do
    case shadow.(
           "SELECT id, epoch, heartbeat_at, status FROM collector_nodes WHERE state = 'leader' ORDER BY heartbeat_at DESC LIMIT 1",
           []
         ) do
      [[id, epoch, heartbeat_at, status]] ->
        Repo.query!(
          """
          INSERT INTO collector_nodes (id, state, epoch, started_at, heartbeat_at, status)
          VALUES ('shadow', 'shadow', $1, $2, $2, $3)
          ON CONFLICT (id) DO UPDATE SET epoch = EXCLUDED.epoch, heartbeat_at = EXCLUDED.heartbeat_at, status = EXCLUDED.status
          """,
          [
            epoch,
            heartbeat_at,
            Map.merge(status || %{}, %{
              "shadow_collector" => id,
              "last_backfill" => %{"at" => DateTime.utc_now(), "filled" => filled}
            })
          ]
        )

      [] ->
        :ok
    end
  end
end
