defmodule KickTracker.Channels.Channel do
  @moduledoc "A tracked channel (project.md §12.2)."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "channels" do
    field :kick_user_id, :integer
    field :kick_channel_id, :integer
    field :chatroom_id, :integer
    field :slug, :string
    field :timezone, :string, default: "Etc/UTC"
    field :tracked_since, :utc_datetime_usec, read_after_writes: true
    field :active, :boolean, default: true
    field :public, :boolean, default: true
    # Chat logging (§12.8): message text kept for this channel, admin only.
    field :chat_log, :boolean, default: false
    field :chat_log_retention_days, :integer, default: 90
    # The picture Kick last gave (§12.9); our copy is in channel_avatars.
    field :avatar_url, :string

    timestamps(type: :utc_datetime_usec)
  end
end
