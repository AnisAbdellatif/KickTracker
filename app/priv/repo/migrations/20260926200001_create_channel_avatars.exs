defmodule KickTracker.Repo.Migrations.CreateChannelAvatars do
  use Ecto.Migration

  # Channel avatars (§12.9): the picture Kick last gave for a channel, and
  # our copy of it, served from our own domain. Expand only.
  def change do
    alter table(:channels) do
      add :avatar_url, :text
    end

    create table(:channel_avatars, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :restrict), primary_key: true
      add :source_url, :text, null: false
      add :content_type, :text, null: false
      add :data, :binary, null: false
      add :sha256, :text, null: false
      add :fetched_at, :timestamptz, null: false
    end
  end
end
