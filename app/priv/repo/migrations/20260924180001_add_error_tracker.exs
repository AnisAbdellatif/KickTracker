defmodule KickTracker.Repo.Migrations.AddErrorTracker do
  use Ecto.Migration

  # ErrorTracker's tables (project.md §18.2).
  def up, do: ErrorTracker.Migration.up(version: 5)
  def down, do: ErrorTracker.Migration.down(version: 1)
end
