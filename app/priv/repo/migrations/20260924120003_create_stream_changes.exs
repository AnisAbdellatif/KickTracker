defmodule KickTracker.Repo.Migrations.CreateStreamChanges do
  use Ecto.Migration

  # Title, category, language and mature-flag changes during a stream, as
  # an append-only log (§12.4). The first row of each field has no old
  # value: it is what the stream started with. `source` says whether Kick's
  # metadata event or our poll saw it.
  def change do
    create table(:stream_changes) do
      add :stream_id, references(:streams, on_delete: :restrict), null: false
      add :occurred_at, :timestamptz, null: false
      add :field, :text, null: false
      add :old_value, :text
      add :new_value, :text
      add :source, :text, null: false
    end

    # The same change learnt twice (a replayed event) is stored once.
    create unique_index(:stream_changes, [:stream_id, :field, :occurred_at])

    create constraint(:stream_changes, :field_known,
             check: "field IN ('title', 'category', 'language', 'mature')"
           )

    create constraint(:stream_changes, :source_known, check: "source IN ('event', 'poll')")
  end
end
