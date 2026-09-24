defmodule KickTracker.Repo.Migrations.CreateChannelEvents do
  use Ecto.Migration

  # Raids and hosts from the chat feed (§2.4, §12.5), once their Pusher
  # event names are recorded. Attributed to streams by time, like follows.
  # `dedup_key` makes a repeated event (a reconnect, two sockets) one row.
  def change do
    create table(:channel_events) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :occurred_at, :timestamptz, null: false
      add :kind, :text, null: false
      add :other_channel, :text
      add :viewers, :integer
      add :dedup_key, :text, null: false
      add :payload, :map, null: false, default: %{}
    end

    create unique_index(:channel_events, [:channel_id, :dedup_key])
    create index(:channel_events, [:channel_id, :occurred_at])
  end
end
