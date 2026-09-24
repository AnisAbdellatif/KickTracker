defmodule KickTracker.Admins.Admin do
  @moduledoc "An admin account (project.md §13.8). No public sign-up: admins invite admins."

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  schema "admins" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :totp_secret, :binary, redact: true
    field :totp_last_step, :integer
    field :disabled_at, :utc_datetime_usec
    belongs_to :invited_by, __MODULE__

    timestamps(type: :utc_datetime_usec)
  end

  @doc "A password being set: at least 12 characters, at most 72."
  def password_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> validate_confirmation(:password, message: "does not match password")
    |> hash_password()
  end

  @doc "A new admin from an invitation."
  def invite_changeset(admin, attrs) do
    admin
    |> change()
    |> put_change(:email, attrs.email)
    |> validate_email()
    |> password_changeset(attrs)
  end

  @doc "Validates an email address (for invitations)."
  def validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> update_change(:email, &String.trim/1)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email, name: :admins_email_index)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      password when is_binary(password) and changeset.valid? ->
        changeset
        |> put_change(:hashed_password, KickTracker.Admins.Password.hash(password))
        |> delete_change(:password)

      _ ->
        changeset
    end
  end
end
