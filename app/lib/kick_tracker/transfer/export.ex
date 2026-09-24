defmodule KickTracker.Transfer.Export do
  @moduledoc """
  Writes an export (see `KickTracker.Transfer`): the chosen channels, and
  with the `:data` scope their history between `from` and `to`, one CSV per
  table from a single snapshot, zipped with a manifest.

  The selection goes into temporary tables first, so every `COPY` query is
  fixed text with no values spliced in.
  """

  alias KickTracker.{Repo, Transfer}

  @type opts :: %{
          scope: :channels | :data,
          channel_ids: [integer()],
          from: DateTime.t() | nil,
          to: DateTime.t() | nil
        }

  # What each table exports, reading the selection tables: x_channels (id,
  # kick_user_id), x_range (from_at, to_at) and x_streams (id). Admin ids
  # are local, so they're left out.
  @in_range "BETWEEN r.from_at AND r.to_at"
  @queries %{
    "removals" => "SELECT * FROM removals",
    "channels" => "SELECT t.* FROM channels t JOIN x_channels x USING (id)",
    "channel_slugs" => "SELECT t.* FROM channel_slugs t JOIN x_channels x ON x.id = t.channel_id",
    "channel_groups" =>
      "SELECT t.* FROM channel_groups t WHERE EXISTS (SELECT 1 FROM channel_group_members m JOIN x_channels x ON x.id = m.channel_id WHERE m.group_id = t.id)",
    "channel_group_members" =>
      "SELECT t.* FROM channel_group_members t JOIN x_channels x ON x.id = t.channel_id",
    "categories" => "SELECT * FROM categories",
    "streams" => "SELECT t.* FROM streams t JOIN x_streams x USING (id)",
    "viewer_samples" =>
      "SELECT t.* FROM viewer_samples t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.observed_at #{@in_range}",
    "subscriber_samples" =>
      "SELECT t.* FROM subscriber_samples t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.observed_at #{@in_range}",
    "follower_samples" =>
      "SELECT t.* FROM follower_samples t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.observed_at #{@in_range}",
    "coverage" =>
      "SELECT t.* FROM coverage t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.from_at <= r.to_at AND (t.to_at IS NULL OR t.to_at >= r.from_at)",
    "stream_changes" => "SELECT t.* FROM stream_changes t JOIN x_streams x ON x.id = t.stream_id",
    "kick_users" => """
    SELECT k.* FROM kick_users k WHERE k.id IN (
      SELECT f.user_id FROM follows f JOIN x_channels x ON x.id = f.channel_id, x_range r WHERE f.occurred_at #{@in_range}
      UNION SELECT e.user_id FROM support_events e JOIN x_channels x ON x.id = e.channel_id, x_range r WHERE e.occurred_at #{@in_range}
      UNION SELECT jsonb_array_elements_text(e.payload -> 'giftee_ids')::bigint FROM support_events e JOIN x_channels x ON x.id = e.channel_id, x_range r WHERE e.occurred_at #{@in_range} AND jsonb_typeof(e.payload -> 'giftee_ids') = 'array'
      UNION SELECT u.user_id FROM chat_stream_users u JOIN x_streams x ON x.id = u.stream_id
      UNION SELECT u.user_id FROM chat_minute_users u JOIN x_channels x ON x.id = u.channel_id, x_range r WHERE u.minute #{@in_range})
    """,
    "follows" =>
      "SELECT t.* FROM follows t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.occurred_at #{@in_range}",
    "support_events" =>
      "SELECT t.* FROM support_events t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.occurred_at #{@in_range}",
    "chat_minutes" =>
      "SELECT t.* FROM chat_minutes t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.minute #{@in_range}",
    "chat_minute_users" =>
      "SELECT t.* FROM chat_minute_users t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.minute #{@in_range}",
    "chat_stream_users" =>
      "SELECT t.* FROM chat_stream_users t JOIN x_streams x ON x.id = t.stream_id",
    "channel_events" =>
      "SELECT t.* FROM channel_events t JOIN x_channels x ON x.id = t.channel_id, x_range r WHERE t.occurred_at #{@in_range}",
    "webhook_events" =>
      "SELECT t.* FROM webhook_events t JOIN x_channels x ON x.kick_user_id = t.broadcaster_user_id, x_range r WHERE t.occurred_at #{@in_range}",
    "stream_overrides" =>
      "SELECT t.id, t.kind, t.stream_id, t.other_stream_id, t.at, t.note, t.revoked_at, t.inserted_at FROM stream_overrides t JOIN x_streams x ON x.id = t.stream_id WHERE t.other_stream_id IS NULL OR t.other_stream_id IN (SELECT id FROM x_streams)",
    "annotations" =>
      "SELECT t.id, t.channel_id, t.from_at, t.to_at, t.text, t.public, t.inserted_at, t.updated_at FROM annotations t, x_range r WHERE (t.channel_id IS NULL OR t.channel_id IN (SELECT id FROM x_channels)) AND t.from_at <= r.to_at AND (t.to_at IS NULL OR t.to_at >= r.from_at)"
  }

  @doc """
  Writes the export to `path` (a `.zip`), using `work_dir` for the CSVs on
  the way. Returns the manifest.
  """
  @spec run(opts(), Path.t(), Path.t()) :: {:ok, map()}
  # sobelow_skip ["Traversal.FileModule"]
  def run(opts, path, work_dir) do
    File.rm_rf!(work_dir)
    File.mkdir_p!(work_dir)
    tables = Transfer.tables(opts.scope)

    # One snapshot for every table; the test sandbox's outer transaction
    # can't change its isolation level.
    snapshot? = Repo.config()[:pool] != Ecto.Adapters.SQL.Sandbox

    {:ok, {rows, channels, removed}} =
      Repo.transaction(
        fn ->
          if snapshot?, do: Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
          select(opts)

          rows = Map.new(tables, &{&1, copy_out(&1, Path.join(work_dir, Transfer.file(&1)))})

          channels =
            Repo.query!(
              "SELECT c.kick_user_id, c.slug FROM channels c JOIN x_channels USING (id) ORDER BY c.slug"
            ).rows
            |> Enum.map(fn [id, slug] -> %{kick_user_id: id, slug: slug} end)

          removed =
            Repo.query!("SELECT kick_user_id FROM removals WHERE kind = 'channel' ORDER BY 1").rows
            |> List.flatten()

          # ON COMMIT only fires at the outermost commit.
          Repo.query!("DROP TABLE x_channels, x_range, x_streams")
          {rows, channels, removed}
        end,
        timeout: :infinity
      )

    manifest =
      Transfer.manifest(%{
        exported_at: DateTime.utc_now(),
        site_name: Application.get_env(:kick_tracker, :site_name),
        schema_version: schema_version(),
        scope: opts.scope,
        from: opts.from,
        to: opts.to,
        channels: channels,
        removed_channels: removed,
        rows: rows
      })

    File.write!(
      Path.join(work_dir, "manifest.json"),
      Jason.encode_to_iodata!(manifest, pretty: true)
    )

    files =
      Enum.map(["manifest.json" | Enum.map(tables, &Transfer.file/1)], &String.to_charlist/1)

    File.rm(path)
    {:ok, _} = :zip.create(String.to_charlist(path), files, cwd: String.to_charlist(work_dir))
    File.rm_rf!(work_dir)
    {:ok, manifest}
  end

  defp select(opts) do
    Repo.query!(
      "CREATE TEMP TABLE x_channels ON COMMIT DROP AS SELECT id, kick_user_id FROM channels WHERE id = ANY($1)",
      [opts.channel_ids]
    )

    Repo.query!(
      "CREATE TEMP TABLE x_range ON COMMIT DROP AS SELECT coalesce($1::timestamptz, '-infinity') AS from_at, coalesce($2::timestamptz, 'infinity') AS to_at",
      [opts.from, opts.to]
    )

    Repo.query!("""
    CREATE TEMP TABLE x_streams ON COMMIT DROP AS
    SELECT s.id FROM streams s JOIN x_channels x ON x.id = s.channel_id, x_range r
    WHERE s.started_at <= r.to_at AND (s.ended_at IS NULL OR s.ended_at >= r.from_at)
    """)
  end

  # sobelow_skip ["SQL.Stream", "Traversal.FileModule"]
  defp copy_out(table, file) do
    sql = "COPY (#{Map.fetch!(@queries, table)}) TO STDOUT WITH (FORMAT csv, HEADER)"

    fd = File.open!(file, [:write, :binary, :raw])

    # Postgres sends one message per row, plus one for the header.
    messages =
      Ecto.Adapters.SQL.stream(Repo, sql)
      |> Enum.reduce(0, fn %{rows: rows, num_rows: n}, acc ->
        :ok = :file.write(fd, rows)
        acc + n
      end)

    :ok = File.close(fd)
    max(messages - 1, 0)
  end

  @doc "The latest migration this database has run."
  @spec schema_version() :: integer()
  def schema_version,
    do: Repo.query!("SELECT max(version) FROM schema_migrations").rows |> hd() |> hd()
end
