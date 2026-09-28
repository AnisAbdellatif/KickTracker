defmodule KickTracker.ApiKeys.ApiKey do
  @moduledoc """
  A key to `/api/v1` (project.md §13.10), issued by an admin: which
  channels and kinds of data it reaches, and its limits. The key itself is
  never stored, only its SHA-256.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias KickTracker.ApiKeys.Access
  alias KickTracker.Series.Resolution

  @type t :: %__MODULE__{}

  schema "api_keys" do
    field :name, :string
    field :contact, :string
    field :token_hash, :binary, redact: true
    field :prefix, :string
    field :admin, :boolean, default: false
    field :all_channels, :boolean, default: true
    field :channel_ids, {:array, :integer}, default: []
    field :group_ids, {:array, :integer}, default: []
    field :scopes, {:array, :string}, default: []
    field :rate_limit, :integer, default: 600
    # A shared key: the rate limit counts per address as well as per key.
    field :per_address, :boolean, default: false
    field :history_days, :integer
    field :min_res, :string
    field :allowed_cidrs, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :created_by_id, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(name contact admin all_channels channel_ids group_ids scopes rate_limit
             per_address history_days min_res allowed_cidrs expires_at)a

  @doc "What an admin sets on a key."
  def changeset(key, attrs) do
    key
    |> cast(attrs, @fields, empty_values: [nil, ""])
    |> update_change(:name, &String.trim/1)
    |> update_change(:allowed_cidrs, fn cidrs ->
      cidrs |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    end)
    |> validate_required([:name, :rate_limit])
    |> validate_length(:name, max: 100)
    |> validate_length(:contact, max: 200)
    |> validate_subset(:scopes, Access.scopes())
    |> validate_number(:rate_limit, greater_than: 0, less_than_or_equal_to: 6000)
    |> validate_number(:history_days, greater_than: 0)
    |> validate_change(:min_res, fn :min_res, res ->
      if Resolution.parse(res), do: [], else: [min_res: "is not a resolution"]
    end)
    |> validate_change(:allowed_cidrs, fn :allowed_cidrs, cidrs ->
      case Enum.reject(cidrs, &Access.cidr_valid?/1) do
        [] -> []
        bad -> [allowed_cidrs: "not an address or CIDR: #{Enum.join(bad, ", ")}"]
      end
    end)
  end
end
