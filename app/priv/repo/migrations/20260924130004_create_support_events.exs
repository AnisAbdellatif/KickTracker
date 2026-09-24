defmodule KickTracker.Repo.Migrations.CreateSupportEvents do
  use Ecto.Migration

  # Subs, resubs, gifted subs and Kicks (§12.5), one row per delivery.
  # `quantity` is the months for a sub or resub, the number of giftees
  # for a gift, the amount for Kicks. `user_id` is the subscriber, gifter
  # or sender, null when anonymous. `payload` keeps what else is useful
  # (giftee ids, expiry, the Kicks gift type), never message text or
  # usernames. Attributed to streams by time, like follows.
  def change do
    create table(:support_events, primary_key: false) do
      add :message_id, :text, primary_key: true
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :occurred_at, :timestamptz, null: false
      add :kind, :text, null: false
      add :user_id, :bigint
      add :quantity, :integer, null: false
      add :tier, :text
      add :payload, :map, null: false, default: %{}
    end

    create index(:support_events, [:channel_id, :occurred_at])

    create constraint(:support_events, :kind_known,
             check: "kind IN ('sub', 'resub', 'gift', 'kicks')"
           )

    create constraint(:support_events, :quantity_positive, check: "quantity > 0")
  end
end
