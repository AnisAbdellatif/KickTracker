defmodule KickTracker.AdminsTest do
  use KickTracker.DataCase, async: true

  alias KickTracker.Admins
  alias KickTracker.Admins.TOTP
  alias KickTracker.Fixtures

  describe "invitations" do
    test "an invitation becomes an account with a password and a TOTP secret" do
      {:ok, token} = Admins.invite(nil, "  first@example.com ")
      invite = Admins.get_invite(token)
      assert invite.sent_to == "first@example.com"

      secret = TOTP.new_secret()
      now = DateTime.utc_now()
      code = TOTP.code(secret, TOTP.step_at(now))

      attrs = %{
        "password" => "a long enough password",
        "password_confirmation" => "a long enough password",
        "code" => code
      }

      assert {:ok, admin} = Admins.accept_invite(invite, secret, attrs, now)
      assert admin.email == "first@example.com"
      assert admin.totp_secret == secret

      # Used once.
      assert Admins.get_invite(token) == nil
      assert {:error, _} = Admins.accept_invite(invite, secret, attrs, now)
    end

    test "is refused with a wrong code, a short password or a mismatched confirmation" do
      {:ok, token} = Admins.invite(nil, "second@example.com")
      invite = Admins.get_invite(token)
      secret = TOTP.new_secret()
      now = DateTime.utc_now()
      good = TOTP.code(secret, TOTP.step_at(now))

      base = %{
        "password" => "a long enough password",
        "password_confirmation" => "a long enough password"
      }

      assert {:error, cs} =
               Admins.accept_invite(invite, secret, Map.put(base, "code", "000000"), now)

      assert %{code: [_]} = errors_on(cs)

      assert {:error, cs} =
               Admins.accept_invite(
                 invite,
                 secret,
                 %{base | "password" => "short", "password_confirmation" => "short"}
                 |> Map.put("code", good),
                 now
               )

      assert %{password: [_]} = errors_on(cs)

      assert {:error, cs} =
               Admins.accept_invite(
                 invite,
                 secret,
                 %{base | "password_confirmation" => "something else"} |> Map.put("code", good),
                 now
               )

      assert %{password_confirmation: [_]} = errors_on(cs)

      # Still usable after failures.
      assert Admins.get_invite(token)
    end

    test "an existing admin's email can't be invited again, whatever the case" do
      {admin, _, _} = Fixtures.admin!("taken@example.com")
      assert {:error, cs} = Admins.invite(admin, "Taken@Example.com")
      assert %{email: ["already has an account"]} = errors_on(cs)
      assert {:error, _} = Admins.invite(admin, "not an email")
    end

    test "a garbled or unknown link finds nothing" do
      assert Admins.get_invite("not-base64!") == nil

      assert Admins.get_invite(Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)) ==
               nil
    end

    test "invitations expire after 7 days and can be revoked" do
      {:ok, token} = Admins.invite(nil, "late@example.com")
      invite = Admins.get_invite(token)

      Repo.query!(
        "UPDATE admin_tokens SET inserted_at = now() - interval '8 days' WHERE id = $1",
        [invite.id]
      )

      assert Admins.get_invite(token) == nil

      {:ok, token} = Admins.invite(nil, "revoked@example.com")
      Admins.revoke_invite(Admins.get_invite(token).id)
      assert Admins.get_invite(token) == nil
    end
  end

  describe "authenticate/4" do
    test "needs the right email (any case), password and a fresh code" do
      {admin, password, secret} = Fixtures.admin!("login@example.com")
      now = DateTime.utc_now()
      code = TOTP.code(secret, TOTP.step_at(now))

      assert {:error, :invalid} =
               Admins.authenticate("login@example.com", "wrong password!", code, now)

      assert {:error, :invalid} =
               Admins.authenticate("login@example.com", password, "000000", now)

      assert {:error, :invalid} = Admins.authenticate("nobody@example.com", password, code, now)

      assert {:ok, %{id: id}} = Admins.authenticate(" LOGIN@example.com", password, code, now)
      assert id == admin.id

      # The same code can't be used twice.
      assert {:error, :invalid} = Admins.authenticate("login@example.com", password, code, now)
    end

    test "a disabled admin can't log in, and loses their sessions" do
      {admin, password, secret} = Fixtures.admin!()
      token = Admins.create_session_token(admin)
      assert Admins.get_by_session_token(token).id == admin.id

      {:ok, _} = Admins.set_disabled(admin, true)
      assert Admins.get_by_session_token(token) == nil

      assert {:error, :invalid} =
               Admins.authenticate(admin.email, password, Fixtures.totp_now(secret))
    end
  end

  describe "sessions" do
    test "a session token lasts 14 days, and ends on logout" do
      {admin, _, _} = Fixtures.admin!()
      token = Admins.create_session_token(admin)
      assert Admins.get_by_session_token(token)

      Admins.delete_session_token(token)
      assert Admins.get_by_session_token(token) == nil

      token = Admins.create_session_token(admin)

      Repo.query!(
        "UPDATE admin_tokens SET inserted_at = now() - interval '15 days' WHERE token = $1",
        [token]
      )

      assert Admins.get_by_session_token(token) == nil
    end

    test "changing the password needs the current one and ends every session" do
      {admin, password, _} = Fixtures.admin!()
      token = Admins.create_session_token(admin)

      assert {:error, cs} =
               Admins.change_password(admin, "not it at all", %{
                 "password" => "a brand new password",
                 "password_confirmation" => "a brand new password"
               })

      assert %{current_password: _} = errors_on(cs)
      assert Admins.get_by_session_token(token)

      assert {:ok, _} =
               Admins.change_password(admin, password, %{
                 "password" => "a brand new password",
                 "password_confirmation" => "a brand new password"
               })

      assert Admins.get_by_session_token(token) == nil
    end

    test "a password that isn't a string is refused, not a crash" do
      {admin, password, _} = Fixtures.admin!()

      assert {:error, cs} =
               Admins.change_password(admin, %{"x" => password}, %{
                 "password" => ["a brand new password"],
                 "password_confirmation" => "a brand new password"
               })

      assert %{current_password: _, password: _} = errors_on(cs)
    end

    test "disabling ends every session with a disconnect, and revokes only their invitations" do
      {admin, _, _} = Fixtures.admin!()
      {other, _, _} = Fixtures.admin!()
      tokens = [Admins.create_session_token(admin), Admins.create_session_token(admin)]

      for t <- tokens,
          do: Phoenix.PubSub.subscribe(KickTracker.PubSub, Admins.live_socket_id(t))

      {:ok, theirs} = Admins.invite(admin, "theirs@example.com")
      {:ok, others} = Admins.invite(other, "others@example.com")

      assert {:ok, %{disabled_at: %DateTime{}}} = Admins.set_disabled(admin, true)

      for t <- tokens do
        topic = Admins.live_socket_id(t)
        assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
        assert Admins.get_by_session_token(t) == nil
      end

      assert Admins.get_invite(theirs) == nil
      assert Admins.get_invite(others)
    end

    test "a session's expiry is 14 days after it began" do
      {admin, _, _} = Fixtures.admin!()
      token = Admins.create_session_token(admin)
      at = Admins.session_expires_at(token)
      assert_in_delta DateTime.diff(at, DateTime.utc_now()), 14 * 24 * 3600, 60
      assert Admins.session_expires_at("unknown") == nil
    end
  end
end
