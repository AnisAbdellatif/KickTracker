defmodule KickTracker.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  # Kick's categories, filled whenever one is seen (§12.4). Keyed on Kick's
  # own id, which viewer samples and stream changes carry.
  def change do
    create table(:categories, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :name, :text, null: false
      add :first_seen_at, :timestamptz, null: false
      add :updated_at, :timestamptz, null: false
    end
  end
end
