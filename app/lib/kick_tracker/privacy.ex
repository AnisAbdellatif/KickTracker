defmodule KickTracker.Privacy do
  @moduledoc """
  Deletion requests (project.md §12.7, §13.8, §18.3): everything held about
  one Kick user, and removing it.

  Removing is the one exception to "raw facts are append-only", because
  the law asks for it. What identifies the person goes; what doesn't stays:

    * their username (`kick_users`) and per-person chat rows are deleted;
    * their follows and support events keep being counted, without their id;
    * raw event bodies naming them are redacted (and marked, since they no
      longer verify against Kick's signature), and so are hosts' payloads
      (`channel_events`).

  `find/1` is read-only (the web role); `delete/1` runs in the collector's
  `Workers.Privacy` job.
  """

  import Ecto.Query
  alias KickTracker.Repo

  @doc "What is held about a Kick user id."
  @spec find(integer()) :: map()
  # sobelow_skip ["SQL.Query"]
  def find(user_id) do
    count = fn sql, param -> Repo.query!(sql, [param]).rows |> hd() |> hd() end
    id = Integer.to_string(user_id)

    %{
      user_id: user_id,
      username: Repo.one(from k in "kick_users", where: k.id == ^user_id, select: k.username),
      chat_minutes: count.("SELECT count(*) FROM chat_minute_users WHERE user_id = $1", user_id),
      chat_streams: count.("SELECT count(*) FROM chat_stream_users WHERE user_id = $1", user_id),
      follows: count.("SELECT count(*) FROM follows WHERE user_id = $1", user_id),
      support_events:
        count.(
          "SELECT count(*) FROM support_events WHERE user_id = $1::text::bigint OR payload::text ~ ('\\m' || $1 || '\\M')",
          id
        ),
      channel_events:
        count.(
          "SELECT count(*) FROM channel_events WHERE payload::text ~ ('\\m' || $1 || '\\M')",
          id
        ),
      # Bodies mentioning the id (possibly inside a longer number).
      webhook_events:
        count.(
          "SELECT count(*) FROM webhook_events WHERE redacted_at IS NULL AND position(convert_to($1, 'UTF8') IN body) > 0",
          id
        )
    }
  end

  @doc "Removes what identifies a Kick user (see the module doc). Returns what changed."
  @spec delete(integer()) :: map()
  def delete(user_id) when is_integer(user_id) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          %{num_rows: minutes} =
            Repo.query!("DELETE FROM chat_minute_users WHERE user_id = $1", [user_id])

          %{num_rows: streams} =
            Repo.query!("DELETE FROM chat_stream_users WHERE user_id = $1", [user_id])

          %{num_rows: follows} =
            Repo.query!("UPDATE follows SET user_id = NULL WHERE user_id = $1", [user_id])

          %{num_rows: support} =
            Repo.query!("UPDATE support_events SET user_id = NULL WHERE user_id = $1", [user_id])

          # Giftee lists and similar keep the gift, not the person.
          support_payloads = scrub_support_payloads(user_id)
          channel_events = scrub_channel_event_payloads(user_id)
          audit = redact_audit_log(user_id)
          %{num_rows: names} = Repo.query!("DELETE FROM kick_users WHERE id = $1", [user_id])
          bodies = redact_bodies(user_id)
          KickTracker.Removals.record(:user, user_id)

          %{
            chat_minutes: minutes,
            chat_streams: streams,
            follows: follows,
            support_events: support + support_payloads,
            channel_events: channel_events,
            usernames: names,
            webhook_events: bodies,
            audit_entries: audit
          }
        end,
        timeout: :infinity
      )

    result
  end

  # The audit log is append-only, except for this: a privacy search logged
  # by an older version named whom it looked for (username or id). The
  # search entry stays, without the name. Runs before `kick_users` loses
  # the username.
  defp redact_audit_log(user_id) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE admin_audit_log SET target = NULL
        WHERE action = 'privacy.find' AND target IS NOT NULL
          AND (target = $1::text
               OR lower(target) = (SELECT lower(username) FROM kick_users WHERE id = $2))
        """,
        [Integer.to_string(user_id), user_id]
      )

    n
  end

  defp scrub_support_payloads(user_id) do
    rows =
      Repo.query!(
        "SELECT message_id, payload FROM support_events WHERE payload::text ~ ('\\m' || $1 || '\\M')",
        [Integer.to_string(user_id)]
      ).rows

    for [id, payload] <- rows, (scrubbed = scrub(payload, user_id)) != payload do
      Repo.query!("UPDATE support_events SET payload = $2 WHERE message_id = $1", [id, scrubbed])
    end
    |> length()
  end

  defp scrub_channel_event_payloads(user_id) do
    rows =
      Repo.query!(
        "SELECT id, payload FROM channel_events WHERE payload::text ~ ('\\m' || $1 || '\\M')",
        [Integer.to_string(user_id)]
      ).rows

    for [id, payload] <- rows, (scrubbed = scrub(payload, user_id)) != payload do
      Repo.query!("UPDATE channel_events SET payload = $2 WHERE id = $1", [id, scrubbed])
    end
    |> length()
  end

  defp redact_bodies(user_id) do
    rows =
      Repo.query!(
        "SELECT message_id, body FROM webhook_events WHERE redacted_at IS NULL AND position(convert_to($1, 'UTF8') IN body) > 0",
        [Integer.to_string(user_id)]
      ).rows

    for [id, body] <- rows,
        {:ok, json} <- [Jason.decode(body)],
        (redacted = scrub(json, user_id)) != json do
      Repo.query!(
        "UPDATE webhook_events SET body = $2, redacted_at = now() WHERE message_id = $1",
        [
          id,
          Jason.encode!(redacted)
        ]
      )
    end
    |> length()
  end

  @doc """
  Removes a user from a decoded JSON value: any object naming them by
  `user_id` or `id` loses its identifying fields, and the id itself
  disappears from lists of ids. Pure.
  """
  @spec scrub(term(), integer()) :: term()
  def scrub(%{} = map, user_id) do
    if map["user_id"] == user_id or (map["id"] == user_id and Map.has_key?(map, "username")) do
      map
      |> Map.new(fn
        {k, _} when k in ~w(user_id id) ->
          {k, nil}

        {k, v} when k in ~w(username slug channel_slug profile_picture identity) ->
          {k, if(is_binary(v), do: "[redacted]", else: nil)}

        {k, v} ->
          {k, scrub(v, user_id)}
      end)
    else
      Map.new(map, fn {k, v} -> {k, scrub(v, user_id)} end)
    end
  end

  def scrub(list, user_id) when is_list(list),
    do: list |> Enum.reject(&(&1 == user_id)) |> Enum.map(&scrub(&1, user_id))

  def scrub(other, _user_id), do: other
end
