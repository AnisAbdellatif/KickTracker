defmodule KickTracker.Repo.Migrations.CreateStreamStats do
  use Ecto.Migration

  # Per-stream figures (§12.6): a cache, rebuilt from the raw tables
  # whenever a stream changes and on demand. Nothing here exists only here.
  # Null means "not known" (no follower reading at the start, say), never 0.
  def change do
    create table(:stream_stats, primary_key: false) do
      add :stream_id, references(:streams, on_delete: :delete_all), primary_key: true
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :computed_at, :timestamptz, null: false
      add :airtime_s, :integer
      add :samples, :integer, null: false
      add :avg_viewers, :float
      add :peak_viewers, :integer
      add :hours_watched, :float, null: false
      add :followers_start, :bigint
      add :followers_end, :bigint
      add :follower_gain, :bigint
      add :follows, :integer, null: false
      add :unique_chatters, :integer, null: false
      add :messages, :integer, null: false
      add :subs, :integer, null: false
      add :resubs, :integer, null: false
      add :gifted_subs, :integer, null: false
      add :kicks, :integer, null: false
    end

    create index(:stream_stats, [:channel_id])
  end
end
