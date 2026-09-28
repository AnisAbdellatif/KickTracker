defmodule KickTracker.Repo.Migrations.AddChannelVisibility do
  use Ecto.Migration

  # Two levels of hiding (project.md §13.2): `live_only` shows a channel
  # only while live, with its current viewers and active chatters, and
  # `hidden` shows it only in the admin. Expand only: `public` stays, kept
  # equal to `visibility = 'public'` by the code that writes either, so a
  # node still reading `public` during a deploy sees a live-only channel
  # as hidden (the safe side). Channels hidden so far may be removal
  # requests, so they become `hidden`.
  def up do
    alter table(:channels) do
      add :visibility, :text, null: false, default: "public"
    end

    create constraint(:channels, :channels_visibility_check,
             check: "visibility IN ('public', 'live_only', 'hidden')"
           )

    execute "UPDATE channels SET visibility = 'hidden' WHERE NOT public"
  end

  def down do
    alter table(:channels) do
      remove :visibility
    end
  end
end
