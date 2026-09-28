defmodule KickTracker.Repo.Migrations.AddApiKeysPerAddress do
  use Ecto.Migration

  # A key shared by many people (one built into a browser extension):
  # its rate limit counts per address, so each of them gets the limit
  # rather than all of them sharing it (project.md §13.10). Expand only.
  def change do
    alter table(:api_keys) do
      add :per_address, :boolean, null: false, default: false
    end
  end
end
