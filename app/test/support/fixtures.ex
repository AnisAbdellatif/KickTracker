defmodule KickTracker.Fixtures do
  @moduledoc "Rows for tests, with obviously fake values."

  alias KickTracker.Channels.Channel
  alias KickTracker.Repo

  @doc "A tracked channel."
  def channel!(attrs \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Channel{
      kick_user_id: Keyword.get(attrs, :kick_user_id, 1_000_000 + n),
      slug: Keyword.get(attrs, :slug, "somestreamer#{n}"),
      chatroom_id: Keyword.get(attrs, :chatroom_id),
      active: Keyword.get(attrs, :active, true)
    })
  end

  @doc """
  An admin with a known password and TOTP secret (returned as
  `{admin, password, secret}`), created through an invitation like a real one.
  """
  def admin!(email \\ nil) do
    n = System.unique_integer([:positive])
    email = email || "admin#{n}@example.com"
    password = "correct horse battery #{n}"
    secret = KickTracker.Admins.TOTP.new_secret()
    {:ok, token} = KickTracker.Admins.invite(nil, email)
    invite = KickTracker.Admins.get_invite(token)
    # A step in the past, so a login "now" isn't refused as a replay.
    past = DateTime.add(DateTime.utc_now(), -120)
    code = KickTracker.Admins.TOTP.code(secret, KickTracker.Admins.TOTP.step_at(past))

    {:ok, admin} =
      KickTracker.Admins.accept_invite(
        invite,
        secret,
        %{"password" => password, "password_confirmation" => password, "code" => code},
        past
      )

    {admin, password, secret}
  end

  @doc "The current TOTP code for a secret."
  def totp_now(secret),
    do: KickTracker.Admins.TOTP.code(secret, KickTracker.Admins.TOTP.step_at(DateTime.utc_now()))

  @doc "All rows of a table as maps, ordered by the given columns."
  def rows(table, order_by) do
    %{columns: cols, rows: rows} =
      Repo.query!("SELECT * FROM #{table} ORDER BY #{Enum.join(order_by, ", ")}")

    Enum.map(rows, fn row -> cols |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new() end)
  end

  @recordings Path.expand("../../../fixtures", __DIR__)

  @doc "Decoded bodies of 200 responses in the recorded fixtures matching `pattern`."
  def recorded_bodies(pattern) do
    @recordings
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
    |> Enum.filter(&(get_in(&1, ["response", "status"]) == 200))
    |> Enum.map(&Jason.decode!(get_in(&1, ["response", "body"])))
  end

  @doc "Raw request bodies of every recorded webhook of this type (as Kick sent them)."
  def recorded_webhooks(event_type) do
    @recordings
    |> Path.join("webhook/*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
    |> Enum.filter(fn rec ->
      Enum.any?(rec["request"]["headers"], &(&1 == ["kick-event-type", event_type]))
    end)
    |> Enum.map(&{&1["request"]["body"], header(&1, "kick-event-message-timestamp")})
  end

  defp header(rec, name),
    do: Enum.find_value(rec["request"]["headers"], fn [k, v] -> if k == name, do: v end)
end
