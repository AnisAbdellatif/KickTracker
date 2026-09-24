defmodule KickTracker.Repo.Migrations.DataQuality do
  use Ecto.Migration

  # Data quality (project.md §19.2).
  def change do
    # Viewer readings that look like glitches (Metrics.Outliers): derived,
    # rebuilt with the rollups; the readings themselves are never changed.
    create table(:viewer_flags, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :delete_all), primary_key: true
      add :observed_at, :timestamptz, primary_key: true
      add :stream_id, references(:streams, on_delete: :delete_all), null: false
      add :reason, :text, null: false
    end

    create index(:viewer_flags, [:stream_id])

    # Webhooks that didn't look the way we parse them (Events.Shape).
    create table(:payload_issues) do
      add :event_type, :text, null: false
      add :event_version, :text, null: false
      add :problem, :text, null: false
      add :count, :integer, null: false, default: 0
      add :first_seen_at, :timestamptz, null: false
      add :last_seen_at, :timestamptz, null: false
      add :example_message_id, :text
    end

    create unique_index(:payload_issues, [:event_type, :event_version, :problem])
  end
end
