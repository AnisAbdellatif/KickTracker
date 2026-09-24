defmodule KickTracker.Repo.Migrations.CreateAdmins do
  use Ecto.Migration

  # Admin tables (project.md §13.8): the only tables besides the other admin
  # ones that the web role writes.
  def change do
    create table(:admins) do
      add :email, :text, null: false
      add :hashed_password, :text, null: false
      add :totp_secret, :binary, null: false
      # The last TOTP step accepted, so a code can't be used twice.
      add :totp_last_step, :bigint
      add :invited_by_id, references(:admins, on_delete: :nilify_all)
      add :disabled_at, :timestamptz

      timestamps(type: :timestamptz)
    end

    create unique_index(:admins, ["lower(email)"], name: :admins_email_index)

    # Session tokens (stored as is, like phx.gen.auth) and invitations
    # (stored hashed: the link is the secret).
    create table(:admin_tokens) do
      add :admin_id, references(:admins, on_delete: :delete_all)
      add :token, :binary, null: false
      add :context, :text, null: false
      add :sent_to, :text

      timestamps(type: :timestamptz, updated_at: false)
    end

    create unique_index(:admin_tokens, [:context, :token])
    create index(:admin_tokens, [:admin_id])

    create constraint(:admin_tokens, :context_known, check: "context IN ('session', 'invite')")

    # Every admin action, who and when (§13.8). Append-only.
    create table(:admin_audit_log) do
      add :admin_id, references(:admins, on_delete: :nilify_all)
      add :admin_email, :text
      add :action, :text, null: false
      add :target, :text
      add :details, :map, null: false, default: %{}
      add :at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:admin_audit_log, [:at])
  end
end
