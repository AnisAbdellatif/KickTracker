defmodule KickTracker.Transfer.Import do
  @moduledoc """
  Merges an export (see `KickTracker.Transfer`) into this database, in one
  transaction: all of it or nothing.

  Every CSV is loaded with `COPY` into a temporary staging table shaped
  like its target, then inserted through maps from the export's ids to
  ours, built on natural keys: channels by `kick_user_id`, streams by
  `(channel, started_at)`, groups by slug. Imports only add (§7): a row
  already here wins, so importing the same file twice changes nothing.

  Removal requests travel too. A channel removed on either side is not
  brought back, and one removed on the other side is deleted here too
  (after the commit, by `Workers.DeleteChannel`); a removed user's
  identifying rows are removed again with `KickTracker.Privacy.delete/1`.

  Imported open coverage periods are closed at the export's time: the
  other collector stopped vouching for them then.

  `tracked_since` travels only with history. The channel list alone brings
  none, so its new channels are tracked from the import and channels
  already here keep their date; claiming the other instance's date would
  make the time between read as a gap.
  """

  alias KickTracker.{Privacy, Repo, Transfer}

  @doc """
  Imports the archive at `path`, extracting into `work_dir`. Returns a
  summary: per table the rows in the file and the rows added, the channels
  created, the channels to delete, and the time range to recompute.
  """
  @spec run(Path.t(), Path.t()) :: {:ok, map()} | {:error, String.t()}
  # sobelow_skip ["Traversal.FileModule"]
  def run(path, work_dir) do
    with {:ok, manifest, files} <- read_manifest(path) do
      File.rm_rf!(work_dir)
      File.mkdir_p!(work_dir)
      csvs = Enum.reject(files, &(&1 == "manifest.json"))

      {:ok, _} =
        :zip.extract(String.to_charlist(path),
          cwd: String.to_charlist(work_dir),
          file_list: Enum.map(csvs, &String.to_charlist/1)
        )

      result =
        Repo.transaction(fn -> merge(manifest, work_dir) end, timeout: :infinity)

      File.rm_rf!(work_dir)
      result
    end
  end

  @doc "Reads and checks an archive's manifest; returns it with the archive's file names."
  @spec read_manifest(Path.t()) :: {:ok, map(), [String.t()]} | {:error, String.t()}
  def read_manifest(path) do
    zip = String.to_charlist(path)

    with {:ok, [_comment | entries]} <- :zip.list_dir(zip),
         files = for({:zip_file, name, _, _, _, _} <- entries, do: List.to_string(name)),
         {:ok, [{_, json}]} <- :zip.extract(zip, [:memory, file_list: [~c"manifest.json"]]),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, manifest} <- Transfer.validate(decoded, files) do
      {:ok, manifest, files}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:ok, []} -> {:error, "no manifest.json in the archive"}
      _ -> {:error, "not a readable .zip export"}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp merge(manifest, work_dir) do
    staged = Map.new(Transfer.tables(), &{&1, stage(&1, work_dir)})

    {added, new_channels} =
      Enum.reduce(statements(manifest), {%{}, []}, fn {table, sql, params}, {added, new} ->
        params = Enum.map(params, &if(&1 == :new_channels, do: new, else: &1))
        result = Repo.query!(sql, params)

        new =
          if table == "channels", do: new ++ List.flatten(result.rows || []), else: new

        {Map.update(added, table, result.num_rows, &(&1 + result.num_rows)), new}
      end)

    removed_users = removed_users_present()
    Enum.each(removed_users, &Privacy.delete/1)

    to_delete =
      Repo.query!(
        "SELECT c.id FROM channels c JOIN removals r ON r.kind = 'channel' AND r.kick_user_id = c.kick_user_id"
      ).rows
      |> List.flatten()

    [[from, to]] =
      Repo.query!(
        "SELECT min(s.started_at), max(coalesce(s.ended_at, now())) FROM streams s JOIN m_streams m ON m.new_id = s.id"
      ).rows

    # ON COMMIT only fires at the outermost commit.
    staging = Enum.map_join(Transfer.tables(), ", ", &"s_#{&1}")
    Repo.query!("DROP TABLE #{staging}, m_channels, m_groups, m_streams")

    %{
      "tables" =>
        Map.new(Transfer.tables(), fn t ->
          {t, %{"in_file" => staged[t], "added" => Map.get(added, t, 0)}}
        end),
      "new_channels" => new_channels,
      "delete_channels" => to_delete,
      "removed_users_reapplied" => length(removed_users),
      "from" => from && DateTime.to_iso8601(from),
      "to" => to && DateTime.to_iso8601(to)
    }
  end

  # Loads a table's CSV into s_<table>; an absent file leaves it empty.
  # sobelow_skip ["SQL.Query", "SQL.Stream", "Traversal.FileModule"]
  defp stage(table, work_dir) do
    Repo.query!("CREATE TEMP TABLE s_#{table} (LIKE #{table} INCLUDING DEFAULTS) ON COMMIT DROP")
    file = Path.join(work_dir, Transfer.file(table))

    if File.exists?(file) do
      columns = header!(table, file)

      stream =
        Ecto.Adapters.SQL.stream(
          Repo,
          "COPY s_#{table} (#{Enum.join(columns, ", ")}) FROM STDIN WITH (FORMAT csv, HEADER)"
        )

      _copied = Enum.into(File.stream!(file, 65_536), stream)
      Repo.query!("SELECT count(*) FROM s_#{table}").rows |> hd() |> hd()
    else
      0
    end
  end

  # The CSV's columns, each one a column of the table here.
  # sobelow_skip ["Traversal.FileModule"]
  defp header!(table, file) do
    line = File.open!(file, [:read, :binary], &IO.binread(&1, :line))

    known =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1",
        [table]
      ).rows
      |> List.flatten()

    columns =
      if is_binary(line), do: line |> String.trim_trailing() |> String.split(","), else: []

    case Enum.reject(columns, &(&1 in known)) do
      [] when columns != [] ->
        columns

      [] ->
        Repo.rollback("#{Transfer.file(table)} has no header")

      unknown ->
        Repo.rollback(
          "#{Transfer.file(table)} has columns this version doesn't know: #{Enum.join(unknown, ", ")}"
        )
    end
  end

  # Removed users whose rows or ids came in with the import.
  defp removed_users_present do
    Repo.query!("""
    SELECT r.kick_user_id FROM removals r WHERE r.kind = 'user' AND (
      r.kick_user_id IN (
        SELECT id FROM s_kick_users UNION SELECT user_id FROM s_follows
        UNION SELECT user_id FROM s_support_events UNION SELECT user_id FROM s_chat_minute_users
        UNION SELECT user_id FROM s_chat_stream_users)
      OR EXISTS (SELECT 1 FROM s_support_events e WHERE e.payload::text ~ ('\\m' || r.kick_user_id || '\\M'))
      OR EXISTS (SELECT 1 FROM s_webhook_events w WHERE position(convert_to(r.kick_user_id::text, 'UTF8') IN w.body) > 0))
    """).rows
    |> List.flatten()
  end

  @not_removed_channel "NOT EXISTS (SELECT 1 FROM removals r WHERE r.kind = 'channel' AND r.kick_user_id = s.kick_user_id)"

  # {table, sql, params}, in order. `:new_channels` stands for the ids of
  # the channels this import created.
  defp statements(manifest) do
    history? = manifest["scope"] == "data"

    [
      {"removals",
       "INSERT INTO removals (kind, kick_user_id, removed_at) SELECT kind, kick_user_id, removed_at FROM s_removals ON CONFLICT DO NOTHING",
       []},
      # A new channel keeps its settings; it's paused if another tracked
      # channel holds its slug now (a rename since).
      {"channels",
       """
       INSERT INTO channels (kick_user_id, kick_channel_id, chatroom_id, slug, timezone, tracked_since, active, public, inserted_at, updated_at)
       SELECT s.kick_user_id, s.kick_channel_id, s.chatroom_id, s.slug, s.timezone,
              #{if history?, do: "s.tracked_since", else: "now()"},
              s.active AND NOT EXISTS (SELECT 1 FROM channels a WHERE a.active AND lower(a.slug) = lower(s.slug)),
              s.public, now(), now()
       FROM s_channels s
       WHERE NOT EXISTS (SELECT 1 FROM channels c WHERE c.kick_user_id = s.kick_user_id) AND #{@not_removed_channel}
       RETURNING id
       """, []},
      # History from before a channel was tracked here moves its start back.
      {"channels_tracked_since",
       "UPDATE channels c SET tracked_since = s.tracked_since FROM s_channels s WHERE c.kick_user_id = s.kick_user_id AND s.tracked_since < c.tracked_since AND $1",
       [history?]},
      {"map",
       "CREATE TEMP TABLE m_channels ON COMMIT DROP AS SELECT s.id AS old_id, c.id AS new_id FROM s_channels s JOIN channels c ON c.kick_user_id = s.kick_user_id WHERE #{@not_removed_channel}",
       []},
      {"channel_slugs",
       "INSERT INTO channel_slugs (channel_id, slug, seen_from, seen_to) SELECT m.new_id, s.slug, s.seen_from, s.seen_to FROM s_channel_slugs s JOIN m_channels m ON m.old_id = s.channel_id WHERE m.new_id = ANY($1)",
       [:new_channels]},
      {"channel_groups",
       "INSERT INTO channel_groups (name, slug, public, inserted_at, updated_at) SELECT name, slug, public, now(), now() FROM s_channel_groups ON CONFLICT (slug) DO NOTHING",
       []},
      {"map",
       "CREATE TEMP TABLE m_groups ON COMMIT DROP AS SELECT s.id AS old_id, g.id AS new_id FROM s_channel_groups s JOIN channel_groups g USING (slug)",
       []},
      {"channel_group_members",
       "INSERT INTO channel_group_members (group_id, channel_id) SELECT g.new_id, m.new_id FROM s_channel_group_members s JOIN m_groups g ON g.old_id = s.group_id JOIN m_channels m ON m.old_id = s.channel_id ON CONFLICT DO NOTHING",
       []},
      {"categories",
       "INSERT INTO categories (id, name, first_seen_at, updated_at) SELECT id, name, first_seen_at, updated_at FROM s_categories ON CONFLICT (id) DO NOTHING",
       []},
      {"streams",
       "INSERT INTO streams (channel_id, started_at, ended_at, end_source, kick_livestream_id) SELECT m.new_id, s.started_at, s.ended_at, s.end_source, s.kick_livestream_id FROM s_streams s JOIN m_channels m ON m.old_id = s.channel_id ON CONFLICT (channel_id, started_at) DO NOTHING",
       []},
      {"map",
       "CREATE TEMP TABLE m_streams ON COMMIT DROP AS SELECT s.id AS old_id, t.id AS new_id FROM s_streams s JOIN m_channels m ON m.old_id = s.channel_id JOIN streams t ON t.channel_id = m.new_id AND t.started_at = s.started_at",
       []},
      {"viewer_samples",
       "INSERT INTO viewer_samples (channel_id, observed_at, stream_id, viewers, category_id) SELECT m.new_id, s.observed_at, ms.new_id, s.viewers, s.category_id FROM s_viewer_samples s JOIN m_channels m ON m.old_id = s.channel_id JOIN m_streams ms ON ms.old_id = s.stream_id ON CONFLICT DO NOTHING",
       []},
      {"subscriber_samples",
       "INSERT INTO subscriber_samples (channel_id, observed_at, active, active_gifted, canceled) SELECT m.new_id, s.observed_at, s.active, s.active_gifted, s.canceled FROM s_subscriber_samples s JOIN m_channels m ON m.old_id = s.channel_id ON CONFLICT DO NOTHING",
       []},
      {"follower_samples",
       "INSERT INTO follower_samples (channel_id, observed_at, followers) SELECT m.new_id, s.observed_at, s.followers FROM s_follower_samples s JOIN m_channels m ON m.old_id = s.channel_id ON CONFLICT DO NOTHING",
       []},
      {"coverage",
       """
       INSERT INTO coverage (channel_id, source, from_at, to_at, ok)
       SELECT m.new_id, s.source, s.from_at, coalesce(s.to_at, greatest(s.from_at, $1)), s.ok
       FROM s_coverage s JOIN m_channels m ON m.old_id = s.channel_id
       WHERE NOT EXISTS (SELECT 1 FROM coverage c WHERE c.channel_id = m.new_id AND c.source = s.source AND c.from_at = s.from_at AND c.ok = s.ok)
       """, [manifest["exported_at"]]},
      {"stream_changes",
       "INSERT INTO stream_changes (stream_id, occurred_at, field, old_value, new_value, source) SELECT ms.new_id, s.occurred_at, s.field, s.old_value, s.new_value, s.source FROM s_stream_changes s JOIN m_streams ms ON ms.old_id = s.stream_id ON CONFLICT (stream_id, field, occurred_at) DO NOTHING",
       []},
      {"kick_users",
       "INSERT INTO kick_users (id, username, seen_at) SELECT id, username, seen_at FROM s_kick_users ON CONFLICT (id) DO NOTHING",
       []},
      {"follows",
       "INSERT INTO follows (message_id, channel_id, occurred_at, user_id) SELECT s.message_id, m.new_id, s.occurred_at, s.user_id FROM s_follows s JOIN m_channels m ON m.old_id = s.channel_id ON CONFLICT (message_id) DO NOTHING",
       []},
      {"support_events",
       "INSERT INTO support_events (message_id, channel_id, occurred_at, kind, user_id, quantity, tier, payload) SELECT s.message_id, m.new_id, s.occurred_at, s.kind, s.user_id, s.quantity, s.tier, s.payload FROM s_support_events s JOIN m_channels m ON m.old_id = s.channel_id ON CONFLICT (message_id) DO NOTHING",
       []},
      {"chat_minutes",
       "INSERT INTO chat_minutes (channel_id, minute, stream_id, messages, chatters) SELECT m.new_id, s.minute, ms.new_id, s.messages, s.chatters FROM s_chat_minutes s JOIN m_channels m ON m.old_id = s.channel_id LEFT JOIN m_streams ms ON ms.old_id = s.stream_id ON CONFLICT DO NOTHING",
       []},
      # Kept 90 days (§7): older rows would only be dropped again.
      {"chat_minute_users",
       "INSERT INTO chat_minute_users (channel_id, minute, user_id, messages) SELECT m.new_id, s.minute, s.user_id, s.messages FROM s_chat_minute_users s JOIN m_channels m ON m.old_id = s.channel_id WHERE s.minute > now() - interval '90 days' ON CONFLICT DO NOTHING",
       []},
      {"chat_stream_users",
       "INSERT INTO chat_stream_users (stream_id, user_id, messages, first_at, last_at) SELECT ms.new_id, s.user_id, s.messages, s.first_at, s.last_at FROM s_chat_stream_users s JOIN m_streams ms ON ms.old_id = s.stream_id ON CONFLICT DO NOTHING",
       []},
      {"channel_events",
       "INSERT INTO channel_events (channel_id, occurred_at, kind, other_channel, viewers, dedup_key, payload) SELECT m.new_id, s.occurred_at, s.kind, s.other_channel, s.viewers, s.dedup_key, s.payload FROM s_channel_events s JOIN m_channels m ON m.old_id = s.channel_id ON CONFLICT (channel_id, dedup_key) DO NOTHING",
       []},
      {"webhook_events",
       """
       INSERT INTO webhook_events (message_id, subscription_id, event_type, event_version, sent_at, occurred_at, signature, body, received_at, receiver, stored_at, processed_at, redacted_at, broadcaster_user_id)
       SELECT s.message_id, s.subscription_id, s.event_type, s.event_version, s.sent_at, s.occurred_at, s.signature, s.body, s.received_at, s.receiver, s.stored_at, s.processed_at, s.redacted_at, s.broadcaster_user_id
       FROM s_webhook_events s
       WHERE s.broadcaster_user_id IN (SELECT c.kick_user_id FROM channels c JOIN m_channels m ON m.new_id = c.id)
       ON CONFLICT (message_id) DO NOTHING
       """, []},
      {"stream_overrides",
       """
       INSERT INTO stream_overrides (kind, stream_id, other_stream_id, at, note, revoked_at, inserted_at)
       SELECT s.kind, ms.new_id, mo.new_id, s.at, s.note, s.revoked_at, s.inserted_at
       FROM s_stream_overrides s JOIN m_streams ms ON ms.old_id = s.stream_id LEFT JOIN m_streams mo ON mo.old_id = s.other_stream_id
       WHERE (s.other_stream_id IS NULL OR mo.new_id IS NOT NULL)
         AND NOT EXISTS (SELECT 1 FROM stream_overrides o WHERE o.kind = s.kind AND o.stream_id = ms.new_id
           AND o.other_stream_id IS NOT DISTINCT FROM mo.new_id AND o.at IS NOT DISTINCT FROM s.at AND o.inserted_at = s.inserted_at)
       """, []},
      {"annotations",
       """
       INSERT INTO annotations (channel_id, from_at, to_at, text, public, inserted_at, updated_at)
       SELECT m.new_id, s.from_at, s.to_at, s.text, s.public, s.inserted_at, s.updated_at
       FROM s_annotations s LEFT JOIN m_channels m ON m.old_id = s.channel_id
       WHERE (s.channel_id IS NULL OR m.new_id IS NOT NULL)
         AND NOT EXISTS (SELECT 1 FROM annotations a WHERE a.channel_id IS NOT DISTINCT FROM m.new_id AND a.from_at = s.from_at AND a.text = s.text)
       """, []}
    ]
  end
end
