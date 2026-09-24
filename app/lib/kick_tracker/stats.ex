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
    rows =
      for c <- changes do
        %{
          stream_id: stream_id,
          occurred_at: c.occurred_at,
          field: c.field,
          old_value: c.old_value,
          new_value: c.new_value,
          source: Atom.to_string(c.source)
        }
      end

    Repo.insert_all("stream_changes", rows, on_conflict: :nothing)
    :ok
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
end
