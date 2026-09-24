defmodule KickTracker.Events.WebhookEvent do
  @moduledoc """
  One delivered webhook, kept permanently exactly as signed (project.md
  §12.5): the source of truth for everything learnt from webhooks, and what
  is replayed if handling changes.
  """

  use Ecto.Schema

  @primary_key {:message_id, :string, autogenerate: false}
  schema "webhook_events" do
    field :subscription_id, :string
    field :event_type, :string
    field :event_version, :string
    field :sent_at, :string
    field :occurred_at, :utc_datetime_usec
    field :signature, :string
    field :body, :binary
    field :received_at, :utc_datetime_usec
    field :receiver, :string
    field :stored_at, :utc_datetime_usec, read_after_writes: true
    field :processed_at, :utc_datetime_usec
    field :broadcaster_user_id, :integer
  end
end
