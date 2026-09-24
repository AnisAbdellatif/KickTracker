defmodule KickTracker.Repo.Migrations.CreateSubscriberSamples do
  use Ecto.Migration

  # Subscriber totals from the 5-minute `/channels` poll (§3.1, §12.5).
  def up do
    create table(:subscriber_samples, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false, primary_key: true
      add :observed_at, :timestamptz, null: false, primary_key: true
      add :active, :integer, null: false
      add :active_gifted, :integer, null: false
      add :canceled, :integer, null: false
    end

    create constraint(:subscriber_samples, :counts_not_negative,
             check: "active >= 0 AND active_gifted >= 0 AND canceled >= 0"
           )

    execute "SELECT create_hypertable('subscriber_samples', by_range('observed_at', INTERVAL '30 days'))"

    execute """
    ALTER TABLE subscriber_samples SET (
      timescaledb.enable_columnstore = true,
      timescaledb.segmentby = 'channel_id',
      timescaledb.orderby = 'observed_at DESC'
    )
    """

    execute "CALL add_columnstore_policy('subscriber_samples', after => INTERVAL '7 days')"
  end

  def down, do: drop(table(:subscriber_samples))
end
