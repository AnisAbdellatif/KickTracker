defmodule KickTracker.Stats do
  @moduledoc """
  Writes and reads of the raw fact tables (project.md §12.5). Every write
  is an upsert on the table's natural key, so replaying anything is safe
  (AGENTS.md §7).
  """

  import Ecto.Query

  alias KickTracker.Repo

  # --- streams -------------------------------------------------------------

  @doc """
  A channel's most recent streams, newest first, with the time of each
  one's latest viewer sample (`last_live_at`): what the sessionizer starts
  from.
  """
  @spec recent_streams(integer(), pos_integer()) :: [map()]
  def recent_streams(channel_id, limit \\ 20) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT s.id, s.started_at, s.ended_at, s.end_source,
               (SELECT max(v.observed_at) FROM viewer_samples v
                 WHERE v.channel_id = s.channel_id AND v.stream_id = s.id)
        FROM streams s
        WHERE s.channel_id = $1
        ORDER BY s.started_at DESC
        LIMIT $2
        """,
        [channel_id, limit]
      )

    for [id, started_at, ended_at, end_source, last_live_at] <- rows do
      %{
        id: id,
        started_at: started_at,
        ended_at: ended_at,
        end_source: end_source,
        last_live_at: last_live_at
      }
    end
  end

  @doc """
  Applies one of the sessionizer's writes and returns the stream's id.
  The SQL keeps the sessionizer's rules even for streams it no longer
  holds in memory: an end from Kick's event always wins, and an end
  inferred from polling only ever moves later.
  """
  @spec apply_stream(integer(), KickTracker.Metrics.Sessionizer.action()) :: integer()
  def apply_stream(channel_id, {:open, started_at}) do
    Repo.query!(
      """
      INSERT INTO streams (channel_id, started_at) VALUES ($1, $2)
      ON CONFLICT (channel_id, started_at) DO NOTHING
      """,
      [channel_id, started_at]
    )

    stream_id!(channel_id, started_at)
  end

  def apply_stream(channel_id, {:reopen, started_at}) do
    Repo.query!(
      """
      UPDATE streams SET ended_at = NULL, end_source = NULL
      WHERE channel_id = $1 AND started_at = $2 AND end_source = 'poll'
      """,
      [channel_id, started_at]
    )

    stream_id!(channel_id, started_at)
  end

  def apply_stream(channel_id, {:close, started_at, ended_at, source}) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO streams AS s (channel_id, started_at, ended_at, end_source)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (channel_id, started_at) DO UPDATE SET
          ended_at = CASE
            WHEN EXCLUDED.end_source = 'event' THEN EXCLUDED.ended_at
            WHEN s.end_source = 'event' THEN s.ended_at
            ELSE GREATEST(s.ended_at, EXCLUDED.ended_at)
          END,
          end_source = CASE
            WHEN EXCLUDED.end_source = 'event' OR s.end_source = 'event' THEN 'event'
            ELSE 'poll'
          END
        RETURNING id
        """,
        [channel_id, started_at, ended_at, Atom.to_string(source)]
      )

    id
  end

  @doc """
  The id of a channel's stream by its start, recording the stream if it
  isn't yet (a sample or chat minute implies it was live). Never reopens
  or changes a stream already there.
  """
  @spec ensure_stream_id(integer(), DateTime.t()) :: integer()
  def ensure_stream_id(channel_id, started_at),
    do: apply_stream(channel_id, {:open, started_at})

  @doc "The id of a channel's stream by its start."
  @spec stream_id!(integer(), DateTime.t()) :: integer()
  def stream_id!(channel_id, started_at) do
    Repo.one!(
      from s in "streams",
        where: s.channel_id == ^channel_id and s.started_at == ^started_at,
        select: s.id
    )
  end

  # --- samples -------------------------------------------------------------

  @doc "One viewer reading. A second reading for the same moment is ignored."
  @spec insert_viewer_sample(map()) :: :ok
  def insert_viewer_sample(sample) do
    insert_samples("viewer_samples", [sample])
  end

  @doc "Subscriber totals from the `/channels` poll."
  @spec insert_subscriber_samples([map()]) :: :ok
  def insert_subscriber_samples([]), do: :ok

  def insert_subscriber_samples(samples), do: insert_samples("subscriber_samples", samples)

  @doc """
  Inserts rows into a hypertable, ignoring rows already there. The first
  row of a new time chunk creates the chunk, which locks the tables its
  foreign keys point to; two processes doing that at once can deadlock,
  so a deadlock is retried once.
  """
  @spec insert_samples(String.t(), [map()]) :: :ok
  def insert_samples(table, rows, retried? \\ false) do
    Repo.insert_all(table, rows, on_conflict: :nothing)
    :ok
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :deadlock_detected and not retried? and
           not Repo.in_transaction?(),
         do: insert_samples(table, rows, true),
         else: reraise(error, __STACKTRACE__)
  end

  # --- metadata ------------------------------------------------------------

  @doc "Title, category, language and mature-flag changes for a stream."
  @spec insert_changes(integer(), [KickTracker.Metrics.Changes.change()]) :: :ok
  def insert_changes(_stream_id, []), do: :ok

  def insert_changes(stream_id, changes) do
    # A change to the value the stream already had at that moment changes
    # nothing (a collector that restarted without its state may see the
    # current values as new): it isn't recorded.
    for c <- changes do
      Repo.query!(
        """
        INSERT INTO stream_changes (stream_id, occurred_at, field, old_value, new_value, source)
        SELECT $1, $2, $3, $4, $5, $6
        WHERE NOT EXISTS (
          SELECT 1 FROM (
            SELECT new_value FROM stream_changes
            WHERE stream_id = $1 AND field = $3 AND occurred_at <= $2
            ORDER BY occurred_at DESC, id DESC LIMIT 1
          ) latest WHERE latest.new_value IS NOT DISTINCT FROM $5
        )
        ON CONFLICT (stream_id, field, occurred_at) DO NOTHING
        """,
        [stream_id, c.occurred_at, c.field, c.old_value, c.new_value, Atom.to_string(c.source)]
      )
    end

    :ok
  end

  @doc "A stream's current values (see `current_values/1`) by its natural key; `{nil, nil}` if unknown."
  @spec current_values(integer(), DateTime.t()) :: {map() | nil, DateTime.t() | nil}
  def current_values(channel_id, started_at) do
    case Repo.one(
           from s in "streams",
             where: s.channel_id == ^channel_id and s.started_at == ^started_at,
             select: s.id
         ) do
      nil -> {nil, nil}
      id -> current_values(id)
    end
  end

  @doc """
  A stream's current title, category, language and mature flag, from its
  change log, and when the latest of them was learnt.
  """
  @spec current_values(integer()) :: {map() | nil, DateTime.t() | nil}
  def current_values(stream_id) do
    rows =
      Repo.all(
        from c in "stream_changes",
          where: c.stream_id == ^stream_id,
          distinct: c.field,
          order_by: [asc: c.field, desc: c.occurred_at, desc: c.id],
          select: {c.field, c.new_value, type(c.occurred_at, :utc_datetime_usec)}
      )

    case rows do
      [] ->
        {nil, nil}

      rows ->
        {Map.new(rows, fn {f, v, _} -> {f, v} end),
         rows |> Enum.map(&elem(&1, 2)) |> Enum.max(DateTime)}
    end
  end

  @doc "Records a category the first time it is seen, and its latest name."
  @spec upsert_category(%{id: integer(), name: String.t()} | nil, DateTime.t()) :: :ok
  def upsert_category(nil, _at), do: :ok

  def upsert_category(%{id: id, name: name}, at) do
    Repo.insert_all(
      "categories",
      [%{id: id, name: name, first_seen_at: at, updated_at: at}],
      on_conflict: {:replace, [:name, :updated_at]},
      conflict_target: :id
    )

    :ok
  end

  # --- chat ------------------------------------------------------------------

  @doc """
  Writes finished chat minutes, each `%{minute:, stream_id:, users: %{user_id
  => %{messages:, first_at:, last_at:}}}`, in one transaction:
  `chat_minute_users` rows (added to, if a late message's minute was
  already written), `chat_minutes` recounted from them, and per-stream
  totals in `chat_stream_users` for minutes inside a stream.
  """
  @spec write_chat(integer(), [map()]) :: :ok
  def write_chat(_channel_id, []), do: :ok

  def write_chat(channel_id, minutes) do
    Repo.transaction(fn ->
      user_rows =
        for m <- minutes, {user_id, u} <- m.users do
          %{channel_id: channel_id, minute: m.minute, user_id: user_id, messages: u.messages}
        end

      for chunk <- Enum.chunk_every(user_rows, 5_000) do
        Repo.insert_all("chat_minute_users", chunk,
          on_conflict:
            from(u in "chat_minute_users",
              update: [set: [messages: fragment("? + EXCLUDED.messages", u.messages)]]
            ),
          conflict_target: [:channel_id, :minute, :user_id]
        )
      end

      for m <- minutes do
        Repo.query!(
          """
          INSERT INTO chat_minutes (channel_id, minute, stream_id, messages, chatters)
          SELECT channel_id, minute, $3::bigint, sum(messages), count(*)
          FROM chat_minute_users WHERE channel_id = $1 AND minute = $2
          GROUP BY channel_id, minute
          ON CONFLICT (channel_id, minute) DO UPDATE SET
            messages = EXCLUDED.messages,
            chatters = EXCLUDED.chatters,
            stream_id = COALESCE(chat_minutes.stream_id, EXCLUDED.stream_id)
          """,
          [channel_id, m.minute, m.stream_id]
        )
      end

      stream_rows =
        for m <- minutes, m.stream_id != nil, {user_id, u} <- m.users do
          %{
            stream_id: m.stream_id,
            user_id: user_id,
            messages: u.messages,
            first_at: u.first_at,
            last_at: u.last_at
          }
        end
        |> merge_stream_rows()

      for chunk <- Enum.chunk_every(stream_rows, 5_000) do
        Repo.insert_all("chat_stream_users", chunk,
          on_conflict:
            from(u in "chat_stream_users",
              update: [
                set: [
                  messages: fragment("? + EXCLUDED.messages", u.messages),
                  first_at: fragment("LEAST(?, EXCLUDED.first_at)", u.first_at),
                  last_at: fragment("GREATEST(?, EXCLUDED.last_at)", u.last_at)
                ]
              ]
            ),
          conflict_target: [:stream_id, :user_id]
        )
      end
    end)

    :ok
  end

  @doc """
  Gives a stream the channel's chat minutes that were written with no
  stream although they fall inside it (from its start, up to its end or
  `until`): minutes the collector wrote before it knew the stream had
  started (a missed start event, the API's lag). Their chatters are added
  to `chat_stream_users`, from `chat_minute_users` (so to minute
  precision for `first_at` and `last_at`).

  Only minutes with no stream change, so running it twice changes nothing.
  `chat_minutes.stream_id` and `chat_stream_users` are derived from
  `chat_minute_users` and the streams' ranges, like the rest of a minute's
  row (it is recounted from them); no raw fact changes.
  """
  @spec attribute_chat(integer(), integer(), DateTime.t()) :: :ok
  def attribute_chat(channel_id, stream_id, until) do
    Repo.query!(
      """
      WITH s AS (SELECT started_at, ended_at FROM streams WHERE id = $2),
      moved AS (
        UPDATE chat_minutes m SET stream_id = $2
        FROM s
        WHERE m.channel_id = $1 AND m.stream_id IS NULL
          AND m.minute >= date_trunc('minute', s.started_at)
          AND m.minute < LEAST(COALESCE(s.ended_at, $3::timestamptz), $3::timestamptz)
        RETURNING m.minute
      )
      INSERT INTO chat_stream_users AS u (stream_id, user_id, messages, first_at, last_at)
      SELECT $2, cu.user_id, sum(cu.messages), min(cu.minute), max(cu.minute)
      FROM chat_minute_users cu
      WHERE cu.channel_id = $1 AND cu.minute IN (SELECT minute FROM moved)
      GROUP BY cu.user_id
      ON CONFLICT (stream_id, user_id) DO UPDATE SET
        messages = u.messages + EXCLUDED.messages,
        first_at = LEAST(u.first_at, EXCLUDED.first_at),
        last_at = GREATEST(u.last_at, EXCLUDED.last_at)
      """,
      [channel_id, stream_id, until]
    )

    :ok
  end

  # One row per stream and user, so one statement never touches a row twice.
  defp merge_stream_rows(rows) do
    rows
    |> Enum.group_by(&{&1.stream_id, &1.user_id})
    |> Enum.map(fn {_, [first | _] = same} ->
      %{
        first
        | messages: Enum.sum_by(same, & &1.messages),
          first_at: same |> Enum.map(& &1.first_at) |> Enum.min(DateTime),
          last_at: same |> Enum.map(& &1.last_at) |> Enum.max(DateTime)
      }
    end)
  end

  @doc "Records a raid or host once, however often it is seen."
  @spec insert_channel_event(map()) :: :ok
  def insert_channel_event(row) do
    Repo.insert_all("channel_events", [row],
      on_conflict: :nothing,
      conflict_target: [:channel_id, :dedup_key]
    )

    :ok
  end
end
