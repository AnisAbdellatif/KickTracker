defmodule KickTracker.Transfers.Transfer do
  @moduledoc "An export or import requested from the admin (see `KickTracker.Transfers`)."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "transfers" do
    field :kind, :string
    field :status, :string, default: "queued"
    field :options, :map, default: %{}
    field :manifest, :map
    field :summary, :map
    field :error, :string
    field :size, :integer
    field :finished_at, :utc_datetime_usec
    belongs_to :admin, KickTracker.Admins.Admin

    timestamps(type: :utc_datetime_usec)
  end
end
