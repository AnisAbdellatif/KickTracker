defmodule KickTracker.Repo.Migrations.CreateHourlyStats do
  use Ecto.Migration

  # Per channel and UTC hour (§12.6): the base for daily, weekday and
  # period figures, which are built from it in the channel's timezone at
  # read time. A cache, recomputed for recent hours by a job and
  # rebuildable for any range. Empty hours have no row (a gap, not a zero).
  def up do
    create table(:hourly_stats, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false, primary_key: true
      add :hour, :timestamptz, null: false, primary_key: true
      add :samples, :integer, null: false, default: 0
      add :avg_viewers, :float
      add :peak_viewers, :integer
      add :hours_watched, :float, null: false, default: 0.0
      add :chat_minutes, :integer, null: false, default: 0
      add :messages, :integer, null: false, default: 0
      add :followers_last, :bigint
      add :follows, :integer, null: false, default: 0
      add :subs, :integer, null: false, default: 0
      add :gifted_subs, :integer, null: false, default: 0
      add :kicks, :integer, null: false, default: 0
      add :computed_at, :timestamptz, null: false
    end

    execute "SELECT create_hypertable('hourly_stats', by_range('hour', INTERVAL '90 days'))"
  end

  def down, do: drop(table(:hourly_stats))
end
