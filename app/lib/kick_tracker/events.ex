defmodule KickTracker.Events do
  @moduledoc """
  Webhook events, from the queue to the database.

  `ingest/1` stores a batch of verified envelopes in one transaction:
  every delivery lands in `webhook_events` (a repeat of a message id is a
  no-op), and for the newly stored ones, the facts that need no channel
  state are written in the same transaction (project.md §10). What needs
  a channel's state (stream status and metadata) stays unprocessed until
  that channel's process handles it.
  """

  import Ecto.Query

  alias KickTracker.Events.{Envelope, Handlers, WebhookEvent}
  alias KickTracker.Repo

  @doc """
  Stores envelopes and writes their facts, all or nothing. Returns the
  envelopes that were new; repeats are left out.
  """
  @spec ingest([Envelope.t()]) :: {:ok, [Envelope.t()]} | {:error, term()}
  def ingest(envelopes) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()
      new_ids = insert(envelopes, now)

      new =
        envelopes
        |> Enum.uniq_by(& &1.message_id)
        |> Enum.filter(&MapSet.member?(new_ids, &1.message_id))

      done = Handlers.write_facts(new)
      mark_processed(done, now)
      new
    end)
  end

  @doc "Marks events as handled."
  @spec mark_processed([String.t()], DateTime.t()) :: :ok
  def mark_processed(message_ids, at \\ DateTime.utc_now())
  def mark_processed([], _at), do: :ok

  def mark_processed(message_ids, at) do
    from(e in WebhookEvent, where: e.message_id in ^message_ids and is_nil(e.processed_at))
    |> Repo.update_all(set: [processed_at: at])

    :ok
  end

  @doc """
  Stream status and metadata events for a Kick broadcaster that are still
  unprocessed, oldest first: what a channel's process catches up on when
  it starts.
  """
  @spec unprocessed_for(integer()) :: [Envelope.t()]
  def unprocessed_for(kick_user_id) do
    from(e in WebhookEvent,
      where: is_nil(e.processed_at) and e.event_type in ^Handlers.channel_state_types(),
      order_by: [asc: e.occurred_at, asc: e.message_id]
    )
    |> Repo.all()
    |> Enum.map(&to_envelope/1)
    |> Enum.filter(&(Handlers.broadcaster_id(&1) == kick_user_id))
  end

  @doc "Every unprocessed event stored before `before`, oldest first (for the retry job)."
  @spec unprocessed_before(DateTime.t(), pos_integer()) :: [Envelope.t()]
  def unprocessed_before(before, limit \\ 500) do
    from(e in WebhookEvent,
      where: is_nil(e.processed_at) and e.stored_at < ^before,
      order_by: [asc: e.stored_at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&to_envelope/1)
  end

  @doc "A stored event as an envelope."
  @spec to_envelope(WebhookEvent.t()) :: Envelope.t()
  def to_envelope(%WebhookEvent{} = e) do
    %Envelope{
      message_id: e.message_id,
      subscription_id: e.subscription_id,
      event_type: e.event_type,
      event_version: e.event_version,
      sent_at: e.sent_at,
      occurred_at: e.occurred_at,
      signature: e.signature,
      body: e.body,
      received_at: e.received_at,
      receiver: e.receiver
    }
  end

  defp insert([], _now), do: MapSet.new()

  defp insert(envelopes, now) do
    rows =
      for e <- envelopes do
        %{
          message_id: e.message_id,
          subscription_id: e.subscription_id,
          event_type: e.event_type,
          event_version: e.event_version,
          sent_at: e.sent_at,
          occurred_at: e.occurred_at,
          signature: e.signature,
          body: e.body,
          received_at: e.received_at,
          receiver: e.receiver,
          stored_at: now,
          broadcaster_user_id: Handlers.broadcaster_id(e)
        }
      end

    {_, inserted} =
      Repo.insert_all(WebhookEvent, rows,
        on_conflict: :nothing,
        conflict_target: :message_id,
        returning: [:message_id]
      )

    MapSet.new(inserted, & &1.message_id)
  end
end
