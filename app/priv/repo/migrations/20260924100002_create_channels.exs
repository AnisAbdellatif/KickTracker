defmodule KickTracker.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  # One row per tracked channel. Our own id, with Kick's broadcaster user id
  # as the unique key: slugs change when a streamer renames (§12.2).
  def change do
    create table(:channels) do
      add :kick_user_id, :bigint, null: false
      add :kick_channel_id, :bigint
      add :chatroom_id, :bigint
      add :slug, :text, null: false
      add :timezone, :text, null: false, default: "Etc/UTC"
      add :tracked_since, :timestamptz, null: false, default: fragment("now()")
      add :active, :boolean, null: false, default: true

      timestamps(type: :timestamptz)
    end

    create unique_index(:channels, [:kick_user_id])

    # Two active channels can't claim the same slug; an inactive one keeps
    # its last slug without blocking a new channel that takes it.
    create unique_index(:channels, ["lower(slug)"],
             where: "active",
             name: :channels_active_slug_index
           )
  end
end
