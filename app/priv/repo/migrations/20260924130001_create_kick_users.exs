defmodule KickTracker.Repo.Migrations.CreateKickUsers do
  use Ecto.Migration

  # The only place usernames live (§12.5, §12.7): facts carry Kick user ids,
  # so a deletion request touches one table plus the raw event bodies.
  def change do
    create table(:kick_users, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :username, :text, null: false
      add :seen_at, :timestamptz, null: false
    end
  end
end
