defmodule KickTracker.Repo.Migrations.CreateAdminCorrections do
  use Ecto.Migration

  # The rest of the admin tables (project.md §13.8). Corrections are
  # layered on top of the raw facts, never edits of them.
  def change do
    create table(:channel_groups) do
      add :name, :text, null: false
      add :slug, :text, null: false
      add :public, :boolean, null: false, default: false
      timestamps(type: :timestamptz)
    end

    create unique_index(:channel_groups, [:slug])

    create table(:channel_group_members, primary_key: false) do
      add :group_id, references(:channel_groups, on_delete: :delete_all), primary_key: true
      add :channel_id, references(:channels, on_delete: :delete_all), primary_key: true
    end

    # exclude: a stream left out of every statistic (a test stream, a
    # rebroadcast). merge: `other_stream_id` is shown as part of
    # `stream_id` (the sessionizer split one stream in two). split: the
    # stream is shown as two, cut at `at`. Revoking keeps the row.
    create table(:stream_overrides) do
      add :kind, :text, null: false
      add :stream_id, references(:streams, on_delete: :restrict), null: false
      add :other_stream_id, references(:streams, on_delete: :restrict)
      add :at, :timestamptz
      add :note, :text
      add :admin_id, references(:admins, on_delete: :nilify_all)
      add :revoked_at, :timestamptz
      timestamps(type: :timestamptz, updated_at: false)
    end

    create index(:stream_overrides, [:stream_id])

    create constraint(:stream_overrides, :kind_known,
             check: "kind IN ('exclude', 'merge', 'split')"
           )

    create constraint(:stream_overrides, :shape,
             check: """
             (kind = 'exclude' AND other_stream_id IS NULL AND at IS NULL)
             OR (kind = 'merge' AND other_stream_id IS NOT NULL AND at IS NULL)
             OR (kind = 'split' AND other_stream_id IS NULL AND at IS NOT NULL)
             """
           )

    execute(
      """
      CREATE VIEW excluded_streams AS
      SELECT DISTINCT stream_id FROM stream_overrides
      WHERE kind = 'exclude' AND revoked_at IS NULL
      """,
      "DROP VIEW excluded_streams"
    )

    # Notes on a channel's timeline ("collector outage", "charity stream"),
    # optionally shown on the public charts.
    create table(:annotations) do
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :from_at, :timestamptz, null: false
      add :to_at, :timestamptz
      add :text, :text, null: false
      add :public, :boolean, null: false, default: false
      add :admin_id, references(:admins, on_delete: :nilify_all)
      timestamps(type: :timestamptz)
    end

    create index(:annotations, [:channel_id, :from_at])

    create table(:settings, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :map, null: false
      timestamps(type: :timestamptz)
    end
  end
end
