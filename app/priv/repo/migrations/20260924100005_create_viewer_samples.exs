defmodule KickTracker.Repo.Migrations.CreateViewerSamples do
  use Ecto.Migration

  # One row per viewer reading, every 60s while live (§3.1). A hypertable
  # partitioned by time, compressed after 7 days, grouped by channel so a
  # channel's history is read as one block (§12.5, §12.7). It carries the
  # category at that moment, so per-category queries need no join.
  def up do
    create table(:viewer_samples, primary_key: false) do
      # TimescaleDB requires the time column in every unique key.
      add :channel_id, references(:channels, on_delete: :restrict), null: false, primary_key: true
      add :observed_at, :utc_datetime_usec, null: false, primary_key: true
      add :stream_id, references(:streams, on_delete: :restrict), null: false
      add :viewers, :integer, null: false
      add :category_id, :bigint
    end

    create constraint(:viewer_samples, :viewers_not_negative, check: "viewers >= 0")

    execute "SELECT create_hypertable('viewer_samples', by_range('observed_at', INTERVAL '7 days'))"

    execute """
    ALTER TABLE viewer_samples SET (
      timescaledb.enable_columnstore = true,
      timescaledb.segmentby = 'channel_id',
      timescaledb.orderby = 'observed_at DESC'
    )
    """

    execute "CALL add_columnstore_policy('viewer_samples', after => INTERVAL '7 days')"
  end

  def down do
    drop table(:viewer_samples)
  end
end
