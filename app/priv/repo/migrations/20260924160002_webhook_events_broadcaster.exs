defmodule KickTracker.Repo.Migrations.WebhookEventsBroadcaster do
  use Ecto.Migration

  # The broadcaster a delivery is about, read from its body when stored, so
  # "last event received per channel" (the health page, alerts) needs no
  # decoding of every body. Null for events stored before this column and
  # for bodies that don't name one. Expand-only: nothing else changes.
  def change do
    alter table(:webhook_events) do
      add :broadcaster_user_id, :bigint
    end

    create index(:webhook_events, [:broadcaster_user_id, :received_at])
    create index(:webhook_events, [:received_at])
  end
end
