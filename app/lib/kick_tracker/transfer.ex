defmodule KickTracker.Transfer do
  @moduledoc """
  Export and import of tracked channels and their history (project.md
  §13.8), to move or merge data between instances or to analyse it
  elsewhere.

  An export is a `.zip` holding `manifest.json` and one CSV per table (with
  a header row, written by Postgres `COPY`). Rows keep their local ids, so
  the CSVs join as they are; an import maps them onto its own rows through
  natural keys (`channels.kick_user_id`, streams by `(channel,
  started_at)`, `message_id`, …), never through the ids.

  Only raw facts and admin corrections travel: derived tables are rebuilt
  after an import (§12.6), and admin accounts, audit log and settings stay
  where they are.

  This module is pure: the table list and the manifest. The work is in
  `Transfer.Export` and `Transfer.Import`, run by `Workers.Transfer` on the
  collector.
  """

  @format "kick_tracker.export"
  @version 1

  # In import order (parents first). `:channels` scope is the channel list
  # alone; `:data` adds the history.
  @channel_tables ~w(removals channels channel_slugs channel_groups channel_group_members)
  @data_tables ~w(categories streams viewer_samples subscriber_samples follower_samples coverage
                  stream_changes kick_users follows support_events chat_minutes chat_minute_users
                  chat_stream_users channel_events webhook_events stream_overrides annotations)

  @doc "Every table an export may hold, in import order."
  @spec tables() :: [String.t()]
  def tables, do: @channel_tables ++ @data_tables

  @doc "The tables exported for a scope."
  @spec tables(:channels | :data) :: [String.t()]
  def tables(:channels), do: @channel_tables
  def tables(:data), do: tables()

  @doc "The file name of a table inside the archive."
  @spec file(String.t()) :: String.t()
  def file(table), do: table <> ".csv"

  @doc """
  The manifest written at the root of an export. `attrs`: `:exported_at`,
  `:site_name`, `:schema_version`, `:scope`, `:from`, `:to` (nil when
  open), `:channels` (`%{kick_user_id, slug}`), `:removed_channels` (Kick
  ids) and `:rows` (table => row count).
  """
  @spec manifest(map()) :: map()
  def manifest(attrs) do
    %{
      "format" => @format,
      "version" => @version,
      "exported_at" => DateTime.to_iso8601(attrs.exported_at),
      "site_name" => attrs.site_name,
      "schema_version" => attrs.schema_version,
      "scope" => Atom.to_string(attrs.scope),
      "from" => attrs.from && DateTime.to_iso8601(attrs.from),
      "to" => attrs.to && DateTime.to_iso8601(attrs.to),
      "channels" =>
        Enum.map(attrs.channels, &%{"kick_user_id" => &1.kick_user_id, "slug" => &1.slug}),
      "removed_channels" => attrs.removed_channels,
      "rows" => attrs.rows
    }
  end

  @doc """
  Checks a decoded manifest and the archive's file names against what this
  version reads. Returns the manifest with `exported_at` parsed.
  """
  @spec validate(term(), [String.t()]) :: {:ok, map()} | {:error, String.t()}
  def validate(manifest, files)

  def validate(%{"format" => @format, "version" => v} = m, files)
      when is_integer(v) and v <= @version do
    known = MapSet.new(["manifest.json" | Enum.map(tables(), &file/1)])
    unknown = Enum.reject(files, &MapSet.member?(known, &1))

    with {:ok, exported_at, _} <- DateTime.from_iso8601(m["exported_at"] || ""),
         [] <- unknown,
         true <- is_list(m["channels"]) and is_map(m["rows"]) do
      {:ok, Map.put(m, "exported_at", exported_at)}
    else
      [_ | _] -> {:error, "unexpected files in the archive: #{Enum.join(unknown, ", ")}"}
      _ -> {:error, "the manifest is incomplete"}
    end
  end

  def validate(%{"format" => @format, "version" => v}, _) when is_integer(v),
    do: {:error, "made by a newer version (format #{v}); update this instance first"}

  def validate(_, _), do: {:error, "not an export from this application"}
end
