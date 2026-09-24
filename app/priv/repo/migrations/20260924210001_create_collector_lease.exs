defmodule KickTracker.Repo.Migrations.CreateCollectorLease do
  use Ecto.Migration

  def change do
    # Which collector collects (project.md §10.1): one lease per name, held
    # with an advisory lock; the epoch goes up at every change of holder.
    create table(:collector_lease, primary_key: false) do
      add :name, :text, primary_key: true
      add :epoch, :bigint, null: false, default: 0
      add :holder, :text
      add :acquired_at, :timestamptz
      add :heartbeat_at, :timestamptz
      add :released_at, :timestamptz
    end

    # Each holder's term: when collection was in whose hands, and why it
    # ended (a gap then has a cause). Also what fences a stale holder's writes.
    create table(:collector_terms, primary_key: false) do
      add :name, :text, primary_key: true
      add :epoch, :bigint, primary_key: true
      add :holder, :text, null: false
      add :started_at, :timestamptz, null: false
      add :ended_at, :timestamptz
      add :end_reason, :text
    end

    # Every collector, leading or standing by, and how it is doing.
    create table(:collector_nodes, primary_key: false) do
      add :id, :text, primary_key: true
      add :state, :text, null: false
      add :epoch, :bigint
      add :started_at, :timestamptz, null: false
      add :heartbeat_at, :timestamptz, null: false
      add :status, :map, null: false, default: %{}
    end

    # How far each local journal has been written (exactly once).
    create table(:collector_journal_marks, primary_key: false) do
      add :journal_id, :text, primary_key: true
      add :last_op, :bigint, null: false
      add :updated_at, :timestamptz, null: false
    end
  end
end
