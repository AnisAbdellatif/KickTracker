defmodule KickTracker.ChatLog do
  @moduledoc """
  Chat logging (project.md §12.8): for channels an admin turned it on
  for, every message as sent (`chat_messages`) and every other chat-feed
  event as sent (`chat_log_events`). Off by default, admin only, never on
  the public site or the data API.

  The one place message text is stored (AGENTS.md §7). It is kept for the
  channel's retention (90 days unless an admin changes it), is removed by
  privacy deletions, and an admin can delete a channel's log for a period.

  Rows are built here from what the chat socket decoded (pure); the
  collector writes them through its journal (`Collector.Ops`); the web
  role reads them.
  """

  import Ecto.Query

  alias KickTracker.Channels
  alias KickTracker.Channels.Channel
  alias KickTracker.Repo

  @max_retention_days 3650

  ## Rows (pure)

  @doc "A `chat_messages` row, without its channel."
  @spec message_row(map(), map()) :: map()
  def message_row(%{sender_id: user_id, at: at} = message, text) do
    %{
      sent_at: at,
      message_id: message[:id] || fallback_id(user_id, at, text[:content]),
      user_id: user_id,
      type: text[:type],
      content: text[:content] || "",
      reply_to_message_id: text[:reply_to_message_id],
      reply_to_user_id: text[:reply_to_user_id]
    }
  end

  # Kick gives every message an id; one without is keyed on what it is.
  defp fallback_id(user_id, at, content),
    do: "x" <> hash([Integer.to_string(user_id), DateTime.to_iso8601(at), content || ""])

  @doc "A `chat_log_events` row, without its channel."
  @spec event_row(String.t(), String.t() | nil, term(), DateTime.t()) :: map()
  def event_row(name, pusher_channel, data, %DateTime{} = at) do
    payload = %{"data" => data}

    %{
      occurred_at: at,
      event: name,
      pusher_channel: pusher_channel,
      payload: payload,
      dedup_key:
        hash([DateTime.to_iso8601(at), name, pusher_channel || "", Jason.encode!(payload)])
    }
  end

  defp hash(parts),
    do: :crypto.hash(:sha256, Enum.intersperse(parts, <<0>>)) |> Base.encode16(case: :lower)

  ## Writes (collector)

  @doc "Stores messages; one already stored is left as it is."
  @spec insert_messages(integer(), [map()]) :: :ok
  def insert_messages(_channel_id, []), do: :ok

  def insert_messages(channel_id, rows) do
    rows
    |> Enum.map(&Map.put(&1, :channel_id, channel_id))
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all("chat_messages", &1,
        on_conflict: :nothing,
        conflict_target: [:channel_id, :message_id, :sent_at]
      )
    )
  end

  @doc "Stores one chat-feed event; the same one twice is stored once."
  @spec insert_event(integer(), map()) :: :ok
  def insert_event(channel_id, row) do
    Repo.insert_all("chat_log_events", [Map.put(row, :channel_id, channel_id)],
      on_conflict: :nothing,
      conflict_target: [:channel_id, :dedup_key]
    )

    :ok
  end

  @doc """
  Deletes what each channel's retention no longer covers, logging on or
  off. Returns the rows deleted.
  """
  @spec prune(DateTime.t()) :: %{messages: non_neg_integer(), events: non_neg_integer()}
  def prune(now \\ DateTime.utc_now()) do
    %{num_rows: messages} =
      Repo.query!(
        """
        DELETE FROM chat_messages m USING channels c
        WHERE m.channel_id = c.id AND m.sent_at < $1::timestamptz - make_interval(days => c.chat_log_retention_days)
        """,
        [now]
      )

    %{num_rows: events} =
      Repo.query!(
        """
        DELETE FROM chat_log_events e USING channels c
        WHERE e.channel_id = c.id AND e.occurred_at < $1::timestamptz - make_interval(days => c.chat_log_retention_days)
        """,
        [now]
      )

    %{messages: messages, events: events}
  end

  @doc "Deletes a channel's log over `[from, to)`. Returns the rows deleted."
  @spec delete_range(integer(), DateTime.t(), DateTime.t()) :: %{
          messages: non_neg_integer(),
          events: non_neg_integer()
        }
  def delete_range(channel_id, from, to) do
    Repo.transaction(fn ->
      %{num_rows: messages} =
        Repo.query!(
          "DELETE FROM chat_messages WHERE channel_id = $1 AND sent_at >= $2 AND sent_at < $3",
          [channel_id, from, to]
        )

      %{num_rows: events} =
        Repo.query!(
          "DELETE FROM chat_log_events WHERE channel_id = $1 AND occurred_at >= $2 AND occurred_at < $3",
          [channel_id, from, to]
        )

      %{messages: messages, events: events}
    end)
    |> elem(1)
  end

  ## Settings (web, an admin table)

  @doc """
  Turns logging on or off for a channel and sets how long its log is
  kept. The channel's processes hear it at once when the collector is
  reachable, and within a minute otherwise (the Manager's sync).
  """
  @spec configure(Channel.t(), boolean(), pos_integer()) ::
          {:ok, Channel.t()} | {:error, :bad_retention}
  def configure(%Channel{} = channel, enabled?, retention_days)
      when is_boolean(enabled?) and is_integer(retention_days) do
    if retention_days in 1..@max_retention_days do
      {:ok, channel} =
        channel
        |> Ecto.Changeset.change(chat_log: enabled?, chat_log_retention_days: retention_days)
        |> Repo.update()

      Channels.announce(channel.id, %{chat_log: enabled?})
      {:ok, channel}
    else
      {:error, :bad_retention}
    end
  end

  @doc "The longest retention an admin can set, in days."
  def max_retention_days, do: @max_retention_days

  ## Reads (web)

  @doc """
  Logged messages, newest first, with the sender's username and the
  channel's slug. Filters (all optional): `:channel_ids`, `:user_ids`,
  `:from`, `:to` (`[from, to)`), `:before` (a `{sent_at, message_id}`
  cursor for the next page); `:limit` (default 200).
  """
  @spec messages(map()) :: [map()]
  def messages(filters) do
    filters
    |> messages_query()
    |> order_by([m], desc: m.sent_at, desc: m.message_id)
    |> limit(^Map.get(filters, :limit, 200))
    |> page(filters[:before])
    |> Repo.all()
  end

  @doc "The same messages as `messages/1`, oldest first, as a stream (inside a transaction)."
  @spec stream_messages(map()) :: Enum.t()
  def stream_messages(filters) do
    filters
    |> messages_query()
    |> order_by([m], asc: m.sent_at, asc: m.message_id)
    |> Repo.stream(max_rows: 2000)
  end

  @doc "Other chat-feed events on logged channels, newest first (filters as `messages/1`, without users)."
  @spec events(map()) :: [map()]
  def events(filters) do
    from(e in "chat_log_events",
      join: c in "channels",
      on: c.id == e.channel_id,
      order_by: [desc: e.occurred_at],
      limit: ^Map.get(filters, :limit, 200),
      select: %{
        channel_id: e.channel_id,
        slug: c.slug,
        occurred_at: e.occurred_at,
        event: e.event,
        payload: e.payload
      }
    )
    |> where_in(:channel_id, filters[:channel_ids])
    |> where_time(:occurred_at, filters[:from], filters[:to])
    |> Repo.all()
  end

  @doc "Channels with a log, or logging on, for the admin's filters."
  @spec channels() :: [map()]
  def channels do
    Repo.all(
      from c in Channel,
        where:
          c.chat_log or
            fragment("EXISTS (SELECT 1 FROM chat_messages m WHERE m.channel_id = ?)", c.id),
        order_by: c.slug,
        select: %{
          id: c.id,
          slug: c.slug,
          chat_log: c.chat_log,
          retention_days: c.chat_log_retention_days
        }
    )
  end

  @doc "Kick user ids for a username (as last seen) or an id typed by an admin."
  @spec find_users(String.t()) :: [integer()]
  def find_users(query) do
    query = String.trim(query)

    case Integer.parse(query) do
      {id, ""} ->
        [id]

      _ ->
        Repo.all(
          from k in "kick_users",
            where: fragment("lower(?)", k.username) == ^String.downcase(query),
            select: k.id
        )
    end
  end

  defp messages_query(filters) do
    from(m in "chat_messages",
      join: c in "channels",
      on: c.id == m.channel_id,
      left_join: k in "kick_users",
      on: k.id == m.user_id,
      select: %{
        channel_id: m.channel_id,
        slug: c.slug,
        sent_at: m.sent_at,
        message_id: m.message_id,
        user_id: m.user_id,
        username: k.username,
        type: m.type,
        content: m.content,
        reply_to_message_id: m.reply_to_message_id,
        reply_to_user_id: m.reply_to_user_id
      }
    )
    |> where_in(:channel_id, filters[:channel_ids])
    |> where_in(:user_id, filters[:user_ids])
    |> where_time(:sent_at, filters[:from], filters[:to])
  end

  defp where_in(query, _field, nil), do: query
  defp where_in(query, field, ids), do: where(query, [x], field(x, ^field) in ^ids)

  defp where_time(query, field, from, to) do
    query
    |> then(&if from, do: where(&1, [x], field(x, ^field) >= ^from), else: &1)
    |> then(&if to, do: where(&1, [x], field(x, ^field) < ^to), else: &1)
  end

  defp page(query, nil), do: query

  defp page(query, {at, id}),
    do: where(query, [m], m.sent_at < ^at or (m.sent_at == ^at and m.message_id < ^id))
end
