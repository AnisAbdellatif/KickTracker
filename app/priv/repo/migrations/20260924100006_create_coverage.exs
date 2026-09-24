defmodule KickTracker.Repo.Migrations.CreateCoverage do
  use Ecto.Migration

  # Our own gaps: when a source was working and when it wasn't, so every
  # statistic can say how complete it is (§12.5, AGENTS.md §7). `to_at` is
  # open while a period is still running.
  def change do
    create table(:coverage) do
      add :channel_id, references(:channels, on_delete: :restrict)
      add :source, :text, null: false
      add :from_at, :utc_datetime_usec, null: false
      add :to_at, :utc_datetime_usec
      add :ok, :boolean, null: false
    end

    create index(:coverage, [:channel_id, :source, :from_at])

    create constraint(:coverage, :source_known,
             check: "source IN ('api', 'chat', 'ingress', 'followers')"
           )

    create constraint(:coverage, :ends_after_start, check: "to_at IS NULL OR to_at >= from_at")
  end
end
