defmodule KickTracker.Repo.Migrations.ChannelsPublic do
  use Ecto.Migration

  # A channel hidden from the public site (a streamer asked to be removed,
  # project.md §18.3). Its data stays until an admin deletes it.
  def change do
    alter table(:channels) do
      add :public, :boolean, null: false, default: true
    end
  end
end
