defmodule KickTracker.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  # API keys (project.md §13.10): an admin table, written by the web role.
  # A key is stored as its SHA-256 only; the key itself is shown once.
  def change do
    create table(:api_keys) do
      add :name, :text, null: false
      add :contact, :text
      add :token_hash, :binary, null: false
      # The key's first characters, to tell keys apart in the admin.
      add :prefix, :text, null: false
      # Reaches every channel and every kind of data, logged chat included.
      add :admin, :boolean, null: false, default: false
      # Which channels a regular key reaches: all, or those listed and
      # those in the listed groups.
      add :all_channels, :boolean, null: false, default: true
      add :channel_ids, {:array, :bigint}, null: false, default: []
      add :group_ids, {:array, :bigint}, null: false, default: []
      add :scopes, {:array, :text}, null: false, default: []
      add :rate_limit, :integer, null: false, default: 600
      # How far back the key reads (nil: all), and its finest resolution.
      add :history_days, :integer
      add :min_res, :text
      # Addresses the key is accepted from, as CIDRs (empty: anywhere).
      add :allowed_cidrs, {:array, :text}, null: false, default: []
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :created_by_id, references(:admins, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:token_hash])
  end
end
