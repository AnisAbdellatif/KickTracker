defmodule KickTracker.Repo.Migrations.CreateTransfersAndRemovals do
  use Ecto.Migration

  def change do
    # Exports and imports requested from the admin (project.md §13.8). The
    # files live in TRANSFER_DIR, named by id; this is their log.
    create table(:transfers) do
      add :kind, :text, null: false
      add :status, :text, null: false, default: "queued"
      add :options, :map, null: false, default: %{}
      add :manifest, :map
      add :summary, :map
      add :error, :text
      add :size, :bigint
      add :admin_id, references(:admins, on_delete: :nilify_all)
      add :finished_at, :timestamptz
      timestamps(type: :timestamptz)
    end

    create index(:transfers, [:inserted_at])
    create constraint(:transfers, :kind_known, check: "kind IN ('export', 'import')")

    create constraint(:transfers, :status_known,
             check: "status IN ('uploaded', 'queued', 'running', 'done', 'failed', 'expired')"
           )

    # Who asked to be removed (§18.3), so an import can't bring them back.
    # Only the Kick id is kept: a removal request can't be honoured later
    # without knowing whom it was for.
    create table(:removals, primary_key: false) do
      add :kind, :text, null: false, primary_key: true
      add :kick_user_id, :bigint, null: false, primary_key: true
      add :removed_at, :timestamptz, null: false
    end

    create constraint(:removals, :kind_known, check: "kind IN ('user', 'channel')")
  end
end
