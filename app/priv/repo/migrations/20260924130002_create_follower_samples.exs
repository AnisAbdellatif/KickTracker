defmodule KickTracker.Repo.Migrations.CreateFollowerSamples do
  use Ecto.Migration

  # Follower totals from v2 (§2.3): every 15 minutes live, daily offline,
  # and at each stream's start and end.
  def up do
    create table(:follower_samples, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false, primary_key: true
      add :observed_at, :timestamptz, null: false, primary_key: true
      add :followers, :bigint, null: false
    end

    create constraint(:follower_samples, :followers_not_negative, check: "followers >= 0")

    execute "SELECT create_hypertable('follower_samples', by_range('observed_at', INTERVAL '90 days'))"

    execute """
    ALTER TABLE follower_samples SET (
      timescaledb.enable_columnstore = true,
      timescaledb.segmentby = 'channel_id',
      timescaledb.orderby = 'observed_at DESC'
    )
    """

    execute "CALL add_columnstore_policy('follower_samples', after => INTERVAL '90 days')"
  end

  def down, do: drop(table(:follower_samples))
end
