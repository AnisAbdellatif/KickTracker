defmodule KickTracker.Repo.Migrations.CreateChannelSlugs do
  use Ecto.Migration

  # Slugs change when a streamer renames: history, never a key (§12.2).
  # The current slug has no `seen_to`.
  def change do
    create table(:channel_slugs) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :slug, :text, null: false
      add :seen_from, :timestamptz, null: false
      add :seen_to, :timestamptz
    end

    create unique_index(:channel_slugs, [:channel_id],
             where: "seen_to IS NULL",
             name: :channel_slugs_current_index
           )

    create index(:channel_slugs, ["lower(slug)"])
  end
end
