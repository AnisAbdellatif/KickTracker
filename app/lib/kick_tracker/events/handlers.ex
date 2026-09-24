defmodule KickTracker.Events.Handlers do
  @moduledoc """
  What each webhook event type means to the tracker.

    * **Channel state** (`livestream.status.updated`,
      `livestream.metadata.updated`): handled by the channel's process,
      which knows the open stream. Left unprocessed until it has.
    * **Facts** (`channel.followed`, `channel.subscription.*`,
      `kicks.gifted`): written to `follows` and `support_events` in the
      same transaction that stores the event, for tracked channels.
    * **Ignored** (`moderation.banned`, `channel.reward.redemption.updated`,
      `chat.message.sent`, and any type Kick adds later): stored, marked
      processed, nothing else. Kept in `webhook_events`, so a later feature
      can replay them.
  """

  import Ecto.Query

  alias KickTracker.Events.{Envelope, Facts}
  alias KickTracker.Repo

  @channel_state ~w(livestream.status.updated livestream.metadata.updated)

  @doc "Event types a channel's process handles."
  @spec channel_state_types() :: [String.t()]
  def channel_state_types, do: @channel_state

  @doc "Whether this event is handed to the channel's process after the commit."
  @spec channel_state?(Envelope.t()) :: boolean()
  def channel_state?(%Envelope{event_type: type}), do: type in @channel_state

  @doc """
  Writes the facts for newly stored events, inside the ingest transaction,
  and returns the message ids that are now fully handled.
  """
  @spec write_facts([Envelope.t()]) :: [String.t()]
  def write_facts(envelopes) do
    facts = Enum.filter(envelopes, &(&1.event_type in Facts.types()))
    channels = channels_by_kick_user(facts)

    parsed =
      for e <- facts,
          channel_id = Map.get(channels, broadcaster_id(e)),
          channel_id != nil,
          result = Facts.parse(e, channel_id),
          result != :none,
          do: result

    {follows, support} =
      Enum.split_with(Enum.map(parsed, &elem(&1, 0)), &match?({:follow, _}, &1))

    insert("follows", Enum.map(follows, &elem(&1, 1)))
    insert("support_events", Enum.map(support, &elem(&1, 1)))

    KickTracker.KickUsers.upsert(
      for {{_kind, row}, users} <- parsed, u <- users, do: {u.id, u.username, row.occurred_at}
    )

    for e <- envelopes, not channel_state?(e), do: e.message_id
  end

  defp channels_by_kick_user([]), do: %{}

  defp channels_by_kick_user(envelopes) do
    ids = envelopes |> Enum.map(&broadcaster_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from c in "channels", where: c.kick_user_id in ^ids, select: {c.kick_user_id, c.id})
    |> Map.new()
  end

  defp insert(_table, []), do: :ok

  defp insert(table, rows) do
    Repo.insert_all(table, rows, on_conflict: :nothing, conflict_target: :message_id)
    :ok
  end

  @doc "The Kick broadcaster an event is about, or nil when its body doesn't say."
  @spec broadcaster_id(Envelope.t()) :: integer() | nil
  def broadcaster_id(%Envelope{} = e) do
    case Envelope.payload(e) do
      {:ok, %{"broadcaster" => %{"user_id" => id}}} when is_integer(id) -> id
      _ -> nil
    end
  end
end
