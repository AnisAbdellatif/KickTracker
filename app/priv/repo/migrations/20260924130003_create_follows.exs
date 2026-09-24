defmodule KickTracker.Repo.Migrations.CreateFollows do
  use Ecto.Migration

  # Every `channel.followed` delivery (§12.5): gross follows, exact.
  # Rebuildable from webhook_events. No stream id: which stream a follow
  # belongs to is read from the time, so a follow stored before its
  # stream's start event arrives is still counted for that stream.
  def change do
    create table(:follows, primary_key: false) do
      add :message_id, :text, primary_key: true
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :occurred_at, :timestamptz, null: false
      add :user_id, :bigint, null: false
    end

    create index(:follows, [:channel_id, :occurred_at])
  end
end
