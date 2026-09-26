defmodule KickTracker.Repo.Migrations.CreateChatLog do
  use Ecto.Migration

  # Chat logging (§12.8): off by default, turned on per channel by an
  # admin. The only place message text is stored. Expand only: two new
  # tables and two columns with defaults.
  def up do
    alter table(:channels) do
      add :chat_log, :boolean, null: false, default: false
      add :chat_log_retention_days, :integer, null: false, default: 90
    end

    create constraint(:channels, :chat_log_retention_days_range,
             check: "chat_log_retention_days BETWEEN 1 AND 3650"
           )

    # One row per message, as sent. Not compressed: it is deleted by
    # channel and period (retention, an admin's deletion, a privacy
    # request), and read by user.
    create table(:chat_messages, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :sent_at, :timestamptz, null: false
      add :message_id, :text, null: false
      add :user_id, :bigint, null: false
      add :type, :text
      add :content, :text, null: false
      add :reply_to_message_id, :text
      add :reply_to_user_id, :bigint
    end

    execute "SELECT create_hypertable('chat_messages', by_range('sent_at', INTERVAL '1 day'))"
    create unique_index(:chat_messages, [:channel_id, :message_id, :sent_at])
    create index(:chat_messages, [:channel_id, "sent_at DESC"])
    create index(:chat_messages, [:user_id, "sent_at DESC"])

    # Every other chat-feed event on a logged channel (bans, deleted
    # messages, clears, pins, polls...), kept as sent until parsed.
    create table(:chat_log_events) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :occurred_at, :timestamptz, null: false
      add :event, :text, null: false
      add :pusher_channel, :text
      add :payload, :map, null: false
      add :dedup_key, :text, null: false
    end

    create unique_index(:chat_log_events, [:channel_id, :dedup_key])
    create index(:chat_log_events, [:channel_id, :occurred_at])
  end

  def down do
    drop table(:chat_log_events)
    drop table(:chat_messages)
    drop constraint(:channels, :chat_log_retention_days_range)

    alter table(:channels) do
      remove :chat_log
      remove :chat_log_retention_days
    end
  end
end
