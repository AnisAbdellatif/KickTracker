defmodule KickTracker.Admins.AdminToken do
  @moduledoc """
  Session tokens and invitations. A session token is stored as is (it only
  lives in a signed cookie); an invitation is stored hashed, since the link
  itself is the secret and travels by hand.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "admin_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :admin, KickTracker.Admins.Admin

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
