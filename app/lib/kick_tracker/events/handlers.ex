defmodule KickTracker.Events.Handlers do
  @moduledoc """
  What each webhook event type means to the tracker.

    * **Channel state** (`livestream.status.updated`,
      `livestream.metadata.updated`): handled by the channel's process,
      which knows the open stream. Left unprocessed until it has.
    * **Ignored** (`moderation.banned`, `channel.reward.redemption.updated`,
      `chat.message.sent`, and any type Kick adds later): stored, marked
      processed, nothing else. Kept in `webhook_events`, so a later feature
      can replay them.
  """

  alias KickTracker.Events.Envelope

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
    for e <- envelopes, not channel_state?(e), do: e.message_id
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
