defmodule KickTracker.Admins do
  @moduledoc """
  Admin accounts (project.md §13.8): password plus TOTP, invite-only.

  The first admin is invited from the command line (`mix
  kick_tracker.admin.invite` in development, `KickTracker.Release.invite/1`
  in a release); after that, admins invite admins from the admin pages.
  """

  import Ecto.Query

  alias KickTracker.Admins.{Admin, AdminToken, Password, TOTP}
  alias KickTracker.Repo

  @session_days 14
  @invite_days 7
  @token_bytes 32

  ## Accounts

  @spec list() :: [Admin.t()]
  def list, do: Repo.all(from a in Admin, order_by: a.id, preload: :invited_by)

  @spec get!(integer()) :: Admin.t()
  def get!(id), do: Repo.get!(Admin, id)

  @spec any?() :: boolean()
  def any?, do: Repo.exists?(Admin)

  @doc """
  Checks all three factors. Every failure looks the same to the caller, and
  an unknown email takes as long as a wrong password.
  """
  @spec authenticate(String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, Admin.t()} | {:error, :invalid}
  def authenticate(email, password, code, at \\ DateTime.utc_now())
      when is_binary(email) and is_binary(password) and is_binary(code) do
    admin =
      Repo.one(
        from a in Admin,
          where: fragment("lower(?)", a.email) == ^String.downcase(String.trim(email))
      )

    with %Admin{disabled_at: nil} <- admin,
         true <- Password.verify(password, admin.hashed_password),
         {:ok, step} <- TOTP.verify(admin.totp_secret, code, at, admin.totp_last_step),
         {1, _} <-
           Repo.update_all(
             from(a in Admin,
               where: a.id == ^admin.id,
               where: is_nil(a.totp_last_step) or a.totp_last_step < ^step
             ),
             set: [totp_last_step: step]
           ) do
      {:ok, %{admin | totp_last_step: step}}
    else
      nil ->
        Password.no_match()
        {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  @doc """
  Changes an admin's password, after checking the current one. Ends all
  their sessions, open live pages included (see `end_sessions/1`).
  """
  @spec change_password(Admin.t(), term(), map()) ::
          {:ok, Admin.t()} | {:error, Ecto.Changeset.t()}
  def change_password(%Admin{} = admin, current, attrs) do
    changeset =
      Admin.password_changeset(admin, strings(attrs, ~w(password password_confirmation)))

    changeset =
      if is_binary(current) and Password.verify(current, admin.hashed_password),
        do: changeset,
        else: Ecto.Changeset.add_error(changeset, :current_password, "is not valid")

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, admin} -> {admin, delete_sessions(admin)}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> after_ending_sessions()
  end

  @doc """
  Disables or re-enables an admin. Disabling ends their sessions, open live
  pages included, and revokes the invitations they created and nobody has
  used yet.
  """
  @spec set_disabled(Admin.t(), boolean()) :: {:ok, Admin.t()}
  def set_disabled(%Admin{} = admin, disabled?) do
    Repo.transaction(fn ->
      tokens =
        if disabled? do
          Repo.delete_all(
            from t in AdminToken, where: t.admin_id == ^admin.id and t.context == "invite"
          )

          delete_sessions(admin)
        else
          []
        end

      admin =
        admin
        |> Ecto.Changeset.change(disabled_at: if(disabled?, do: DateTime.utc_now()))
        |> Repo.update!()

      {admin, tokens}
    end)
    |> after_ending_sessions()
  end

  defp delete_sessions(%Admin{id: id}) do
    {_, tokens} =
      Repo.delete_all(
        from t in AdminToken,
          where: t.admin_id == ^id and t.context == "session",
          select: t.token
      )

    tokens
  end

  # Once the tokens are gone for good (committed), closes their live pages.
  defp after_ending_sessions({:ok, {admin, tokens}}) do
    end_sessions(tokens)
    {:ok, admin}
  end

  defp after_ending_sessions({:error, _} = error), do: error

  @doc """
  Disconnects the live pages of these session tokens: each session's
  socket is identified by `live_socket_id/1`, and a `"disconnect"`
  broadcast to it closes the socket. A deleted token then fails the
  reconnection's mount.
  """
  @spec end_sessions([binary()]) :: :ok
  def end_sessions(tokens) do
    for token <- tokens do
      topic = live_socket_id(token)

      Phoenix.PubSub.broadcast(KickTracker.PubSub, topic, %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect",
        payload: %{}
      })
    end

    :ok
  end

  @doc "The id of the live socket a session token opens (`:live_socket_id` in the session)."
  @spec live_socket_id(binary()) :: String.t()
  def live_socket_id(token), do: "admin_sessions:#{Base.url_encode64(token)}"

  # Only strings reach the changesets and hashing: a nested map or a list
  # from a crafted form is treated as missing.
  defp strings(attrs, keys) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    Map.new(keys, fn k -> {k, if(is_binary(attrs[k]), do: attrs[k])} end)
  end

  @doc """
  The sandbox's automatic admin (`KickTrackerWeb.AdminAuth`), created the
  first time with a random password and TOTP secret nobody holds: it can
  only be used through the automatic sign-in.
  """
  @spec ensure_autologin_admin(String.t()) :: Admin.t()
  def ensure_autologin_admin(email) do
    Repo.get_by(Admin, email: email) ||
      (
        password = Base.url_encode64(:crypto.strong_rand_bytes(32))

        %Admin{totp_secret: TOTP.new_secret()}
        |> Admin.invite_changeset(%{
          email: email,
          password: password,
          password_confirmation: password
        })
        |> Repo.insert()
        # Two first requests at once: the other one made it.
        |> case do
          {:ok, admin} -> admin
          {:error, _taken} -> Repo.get_by!(Admin, email: email)
        end
      )
  end

  ## Sessions

  @doc "A new session token for the cookie."
  @spec create_session_token(Admin.t()) :: binary()
  def create_session_token(%Admin{} = admin) do
    token = :crypto.strong_rand_bytes(@token_bytes)
    Repo.insert!(%AdminToken{admin_id: admin.id, token: token, context: "session"})
    token
  end

  @doc "The admin a session token belongs to, while valid and the admin enabled."
  @spec get_by_session_token(binary()) :: Admin.t() | nil
  def get_by_session_token(token) when is_binary(token) do
    Repo.one(
      from t in AdminToken,
        join: a in assoc(t, :admin),
        where: t.token == ^token and t.context == "session",
        where: t.inserted_at > ago(@session_days, "day"),
        where: is_nil(a.disabled_at),
        select: a
    )
  end

  @doc """
  When a session token stops being valid by age (nil for an unknown
  token). Live pages check it so a page left open doesn't outlive its
  session.
  """
  @spec session_expires_at(binary()) :: DateTime.t() | nil
  def session_expires_at(token) when is_binary(token) do
    Repo.one(
      from t in AdminToken,
        where: t.token == ^token and t.context == "session",
        select: t.inserted_at
    )
    |> case do
      nil -> nil
      at -> DateTime.add(at, @session_days * 24 * 3600)
    end
  end

  @spec delete_session_token(binary()) :: :ok
  def delete_session_token(token) do
    Repo.delete_all(from t in AdminToken, where: t.token == ^token and t.context == "session")
    :ok
  end

  ## Invitations

  @doc """
  Invites an email address. Returns the token for the link
  (`/admin/invite?token=<token>`: in the query, which request logs leave
  out), which is shown once and stored only hashed.
  `inviter` is nil for the first admin, invited from the command line.
  """
  @spec invite(Admin.t() | nil, String.t()) :: {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def invite(inviter, email) do
    changeset =
      {%{}, %{email: :string}}
      |> Ecto.Changeset.cast(%{email: email}, [:email])
      |> Admin.validate_email()
      |> Ecto.Changeset.validate_change(:email, fn :email, email ->
        if Repo.exists?(
             from a in Admin, where: fragment("lower(?)", a.email) == ^String.downcase(email)
           ),
           do: [email: "already has an account"],
           else: []
      end)

    with {:ok, %{email: email}} <- Ecto.Changeset.apply_action(changeset, :insert) do
      raw = :crypto.strong_rand_bytes(@token_bytes)

      Repo.insert!(%AdminToken{
        admin_id: inviter && inviter.id,
        token: :crypto.hash(:sha256, raw),
        context: "invite",
        sent_to: email
      })

      {:ok, Base.url_encode64(raw, padding: false)}
    end
  end

  @doc "The invitation behind a link, while valid."
  @spec get_invite(String.t()) :: AdminToken.t() | nil
  def get_invite(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} ->
        Repo.one(
          from t in AdminToken,
            where: t.token == ^:crypto.hash(:sha256, raw) and t.context == "invite",
            where: t.inserted_at > ago(@invite_days, "day")
        )

      _ ->
        nil
    end
  end

  def get_invite(_), do: nil

  @doc "Pending invitations, newest first."
  @spec list_invites() :: [AdminToken.t()]
  def list_invites,
    do:
      Repo.all(
        from t in AdminToken,
          where: t.context == "invite" and t.inserted_at > ago(@invite_days, "day"),
          order_by: [desc: t.inserted_at],
          preload: :admin
      )

  @spec revoke_invite(integer()) :: :ok
  def revoke_invite(id) do
    Repo.delete_all(from t in AdminToken, where: t.id == ^id and t.context == "invite")
    :ok
  end

  @doc """
  Accepts an invitation: sets the password and the TOTP secret, which the
  invitee proves they enrolled by entering a current code. The invitation
  is used up.
  """
  @spec accept_invite(AdminToken.t(), binary(), map(), DateTime.t()) ::
          {:ok, Admin.t()} | {:error, Ecto.Changeset.t()}
  def accept_invite(
        %AdminToken{context: "invite"} = invite,
        totp_secret,
        attrs,
        at \\ DateTime.utc_now()
      ) do
    attrs = strings(attrs, ~w(password password_confirmation code))

    changeset =
      %Admin{totp_secret: totp_secret, invited_by_id: invite.admin_id}
      |> Admin.invite_changeset(%{
        email: invite.sent_to,
        password: attrs["password"],
        password_confirmation: attrs["password_confirmation"]
      })

    changeset =
      case TOTP.verify(totp_secret, attrs["code"] || "", at) do
        {:ok, step} -> Ecto.Changeset.put_change(changeset, :totp_last_step, step)
        :error -> Ecto.Changeset.add_error(changeset, :code, "is not the current code")
      end

    Repo.transaction(fn ->
      # Used once: a second acceptance finds nothing to delete. The row is
      # checked again here, not trusted from when the page was opened: an
      # invitation revoked (or its inviter disabled) or expired since then
      # is gone or too old.
      case Repo.delete_all(
             from t in AdminToken,
               where: t.id == ^invite.id and t.token == ^invite.token,
               where: t.context == "invite" and t.inserted_at > ago(@invite_days, "day")
           ) do
        {1, _} ->
          case Repo.insert(changeset) do
            {:ok, admin} -> admin
            {:error, changeset} -> Repo.rollback(changeset)
          end

        _ ->
          changeset
          |> Ecto.Changeset.add_error(:email, "invitation already used or expired")
          # So the form shows it.
          |> Map.put(:action, :insert)
          |> Repo.rollback()
      end
    end)
  end
end
