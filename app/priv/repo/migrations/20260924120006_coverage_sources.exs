defmodule KickTracker.Repo.Migrations.CoverageSources do
  use Ecto.Migration

  # Coverage for the 5-minute `/channels` poll (subscriber totals) is kept
  # apart from the 60s `/livestreams` poll (`api`): different cadence,
  # different data. Only widens the allowed values.
  def up do
    drop constraint(:coverage, :source_known)

    create constraint(:coverage, :source_known,
             check: "source IN ('api', 'subscribers', 'chat', 'ingress', 'followers')"
           )
  end

  def down do
    drop constraint(:coverage, :source_known)

    create constraint(:coverage, :source_known,
             check: "source IN ('api', 'chat', 'ingress', 'followers')"
           )
  end
end
