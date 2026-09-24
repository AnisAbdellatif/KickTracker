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
      new_ids = envelopes |> insert(now) |> MapSet.new()

      new =
        envelopes
        |> Enum.uniq_by(& &1.message_id)
        |> Enum.filter(&MapSet.member?(new_ids, &1.message_id))

      done = Handlers.write_facts(new)
      mark_processed(done, now)
      record_shape_problems(new, now)
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
    # Filtered in SQL on the stored broadcaster; rows stored before that
    # column existed have it null and are checked by their body.
    from(e in WebhookEvent,
      where: is_nil(e.processed_at) and e.event_type in ^Handlers.channel_state_types(),
      where: e.broadcaster_user_id == ^kick_user_id or is_nil(e.broadcaster_user_id),
      order_by: [asc: e.occurred_at, asc: e.message_id]
    )
    |> Repo.all()
    |> Enum.map(&to_envelope/1)
    |> Enum.filter(&(Handlers.broadcaster_id(&1) == kick_user_id))
  end

  @doc """
  One page of the unprocessed events stored before `before`, oldest first
  (for the retry job), and the cursor for the next page (nil after the
  last). Options: `:after` (a cursor), `:exclude` (broadcaster ids to leave
  out: channels whose events can't be handled now), `:limit` (500).
  """
  @spec unprocessed_page(DateTime.t(), keyword()) :: {[Envelope.t()], term() | nil}
  def unprocessed_page(before, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)
    exclude = Keyword.get(opts, :exclude, [])

    query =
      from(e in WebhookEvent,
        where: is_nil(e.processed_at) and e.stored_at < ^before,
        order_by: [asc: e.stored_at, asc: e.message_id],
        limit: ^limit
      )

    query =
      case Keyword.get(opts, :after) do
        nil ->
          query

        {stored_at, message_id} ->
          where(
            query,
            [e],
            e.stored_at > ^stored_at or (e.stored_at == ^stored_at and e.message_id > ^message_id)
          )
      end

    query =
      if exclude == [],
        do: query,
        else:
          where(
            query,
            [e],
            is_nil(e.broadcaster_user_id) or e.broadcaster_user_id not in ^exclude
          )

    rows = Repo.all(query)

    cursor =
      case List.last(rows) do
        %WebhookEvent{} = last when length(rows) == limit -> {last.stored_at, last.message_id}
        _ -> nil
      end

    {Enum.map(rows, &to_envelope/1), cursor}
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

  # Counted per type, version and problem, so a change on Kick's side shows
  # up as one alert with a count, not one per event (§19.2).
  defp record_shape_problems(envelopes, now) do
    rows =
      for e <- envelopes, problem <- KickTracker.Events.Shape.check(e) do
        %{
          event_type: e.event_type,
          event_version: e.event_version,
          problem: problem,
          count: 1,
          first_seen_at: now,
          last_seen_at: now,
          example_message_id: e.message_id
        }
      end

    if rows != [] do
      rows
      |> Enum.group_by(&{&1.event_type, &1.event_version, &1.problem})
      |> Enum.map(fn {_, [first | _] = same} -> %{first | count: length(same)} end)
      |> then(
        &Repo.insert_all("payload_issues", &1,
          on_conflict:
            from(i in "payload_issues",
              update: [
                inc: [count: fragment("EXCLUDED.count")],
                set: [last_seen_at: fragment("EXCLUDED.last_seen_at")]
              ]
            ),
          conflict_target: [:event_type, :event_version, :problem]
        )
      )
    end

    :ok
  end

  defp insert([], _now), do: []

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

    Enum.map(inserted, & &1.message_id)
  end
end
