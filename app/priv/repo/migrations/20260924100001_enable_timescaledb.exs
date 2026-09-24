defmodule KickTracker.Repo.Migrations.EnableTimescaledb do
  use Ecto.Migration

  # TimescaleDB turns time-series tables into hypertables (project.md §12.1).
  def up, do: execute("CREATE EXTENSION IF NOT EXISTS timescaledb")
  def down, do: execute("DROP EXTENSION IF EXISTS timescaledb")
end
