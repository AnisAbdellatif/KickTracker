defmodule KickTracker.Channels.Channel do
  @moduledoc "A tracked channel (project.md §12.2)."

  use Ecto.Schema

  schema "channels" do
    field :kick_user_id, :integer
    field :kick_channel_id, :integer
    field :chatroom_id, :integer
    field :slug, :string
    field :timezone, :string, default: "Etc/UTC"
    field :tracked_since, :utc_datetime_usec, read_after_writes: true
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end
end
