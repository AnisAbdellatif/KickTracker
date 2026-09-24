defmodule KickTracker.Repo.Migrations.CoverageCollector do
  use Ecto.Migration

  # Which collector a coverage period comes from: null for this
  # deployment's own, "shadow" for periods filled from the shadow
  # collector (project.md §10.5). Expand only.
  def change do
    alter table(:coverage) do
      add :collector, :text
    end
  end
end
