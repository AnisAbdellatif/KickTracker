defmodule KickTracker.Repo.Migrations.CreateAlerts do
  use Ecto.Migration

  # Open and past alerts (project.md §18.2): one row per problem while it
  # lasts, so it is notified when it starts and when it is resolved, not
  # every minute.
  def change do
    create table(:alerts) do
      add :key, :text, null: false
      add :message, :text, null: false
      add :first_at, :timestamptz, null: false
      add :last_at, :timestamptz, null: false
      add :notified_at, :timestamptz
      add :resolved_at, :timestamptz
    end

    create unique_index(:alerts, [:key],
             where: "resolved_at IS NULL",
             name: :alerts_open_key_index
           )

    create index(:alerts, [:first_at])
  end
end
