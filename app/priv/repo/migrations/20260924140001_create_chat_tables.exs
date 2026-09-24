defmodule KickTracker.Repo.Migrations.CreateChatTables do
  use Ecto.Migration

  # Chat at two levels of detail (§3.4, §12.3). No text, ever: only who,
  # when and how many.
  def up do
    # Per channel and minute: messages, and distinct chatters in that minute.
    # Kept forever. Offline chat has no stream.
    create table(:chat_minutes, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false, primary_key: true
      add :minute, :timestamptz, null: false, primary_key: true
      add :stream_id, references(:streams, on_delete: :restrict)
      add :messages, :integer, null: false
      add :chatters, :integer, null: false
    end

    hypertable("chat_minutes", "minute", "7 days")

    # Per channel, minute and chatter: any window of active chatters inside
    # a stream. Kept 90 days.
    create table(:chat_minute_users, primary_key: false) do
      add :channel_id, references(:channels, on_delete: :restrict), null: false, primary_key: true
      add :minute, :timestamptz, null: false, primary_key: true
      add :user_id, :bigint, null: false, primary_key: true
      add :messages, :integer, null: false
    end

    hypertable("chat_minute_users", "minute", "1 day")
    execute "SELECT add_retention_policy('chat_minute_users', drop_after => INTERVAL '90 days')"

    # Per stream and chatter: unique chatters, returning vs new, overlap,
    # top chatters. Kept forever.
    create table(:chat_stream_users, primary_key: false) do
      add :stream_id, references(:streams, on_delete: :restrict), null: false, primary_key: true
      add :user_id, :bigint, null: false, primary_key: true
      add :messages, :integer, null: false
      add :first_at, :timestamptz, null: false
      add :last_at, :timestamptz, null: false
    end

    create index(:chat_stream_users, [:user_id])
  end

  def down do
    drop table(:chat_stream_users)
    drop table(:chat_minute_users)
    drop table(:chat_minutes)
  end

  defp hypertable(table, column, chunk) do
    execute "SELECT create_hypertable('#{table}', by_range('#{column}', INTERVAL '#{chunk}'))"

    execute """
    ALTER TABLE #{table} SET (
      timescaledb.enable_columnstore = true,
      timescaledb.segmentby = 'channel_id',
      timescaledb.orderby = '#{column} DESC'
    )
    """

    execute "CALL add_columnstore_policy('#{table}', after => INTERVAL '7 days')"
  end
end
