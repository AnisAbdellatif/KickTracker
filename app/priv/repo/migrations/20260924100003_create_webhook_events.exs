defmodule KickTracker.Repo.Migrations.CreateWebhookEvents do
  use Ecto.Migration

  # Every delivered event, permanently: the source of truth for anything
  # learnt from webhooks, and what gets replayed if the handling changes
  # (§8.2, §12.5). Mirrors the envelope (contracts/envelope.md).
  def change do
    create table(:webhook_events, primary_key: false) do
      # Kick's id for the delivery; unique, so a repeated delivery is a no-op.
      add :message_id, :text, primary_key: true
      add :subscription_id, :text, null: false
      add :event_type, :text, null: false
      add :event_version, :text, null: false

      # Kept exactly as received: `message_id.sent_at.body` is the signed
      # text, so the body is raw bytes (jsonb would reorder and reformat it)
      # and `sent_at` the header's own string. `occurred_at` is it parsed.
      add :sent_at, :text, null: false
      add :occurred_at, :timestamptz, null: false
      add :signature, :text, null: false
      add :body, :binary, null: false

      add :received_at, :timestamptz, null: false
      add :receiver, :text, null: false
      add :stored_at, :timestamptz, null: false, default: fragment("now()")
      add :processed_at, :timestamptz
    end

    create index(:webhook_events, [:event_type, :occurred_at])

    # What still needs handling, cheap to find however large the table grows.
    create index(:webhook_events, [:stored_at],
             where: "processed_at IS NULL",
             name: :webhook_events_unprocessed_index
           )
  end
end
