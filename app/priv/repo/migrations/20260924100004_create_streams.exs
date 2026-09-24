defmodule KickTracker.Repo.Migrations.CreateStreams do
  use Ecto.Migration

  # A stream is identified by its channel and Kick's own `started_at`
  # (§3.3): Kick sends no livestream id, and both the webhook and the poll
  # report the same `started_at`, confirmed on real recordings.
  def change do
    create table(:streams) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :started_at, :timestamptz, null: false
      add :ended_at, :timestamptz
      # How the end was learnt: Kick's end event, or the safety-net poll.
      add :end_source, :text
      # v2's id, when known; never relied on.
      add :kick_livestream_id, :bigint
    end

    create unique_index(:streams, [:channel_id, :started_at])

    create constraint(:streams, :ended_after_started,
             check: "ended_at IS NULL OR ended_at >= started_at"
           )

    create constraint(:streams, :end_source_known,
             check: "end_source IS NULL OR end_source IN ('event', 'poll')"
           )

    create constraint(:streams, :end_source_with_end,
             check: "(ended_at IS NULL) = (end_source IS NULL)"
           )
  end
end
