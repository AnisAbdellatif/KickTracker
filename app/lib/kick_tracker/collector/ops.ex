defmodule KickTracker.Collector.Ops do
  @moduledoc """
  The writes the collector makes, as data (project.md §10.2): what goes
  into the `Collector.Journal`, and how each is applied to Postgres.

  Operations name streams by their natural key `(channel, started_at)`,
  never by id, so they can be made while the database is unreachable and
  applied later. Applying one is an upsert on natural keys (AGENTS.md §7);
  the Writer applies each exactly once in any case.

    * `{:stream, channel_id, action}` — a sessionizer action (open, reopen, close)
    * `{:viewer_sample, channel_id, started_at, at, viewers, category_id}`
    * `{:subscriber_samples, rows}`
    * `{:follower_sample, channel_id, at, followers}`
    * `{:coverage, channel_ids, source, ok?, at, max_gap_s}`
    * `{:changes, channel_id, started_at, changes}`
    * `{:category, %{id, name} | nil, at}`
    * `{:chat, channel_id, minutes}` — each `%{minute, started_at, users}`
    * `{:chat_stream, channel_id, started_at, until}` — chat written with no
      stream before this stream was known, up to `until`, is the stream's
    * `{:kick_users, [{id, username, seen_at}]}`
    * `{:processed, message_ids}` — stream events handled
    * `{:channel_ids, channel_id, kick_channel_id, chatroom_id}`
    * `{:slug, channel_id, slug, at}` — the slug Kick reports now
    * `{:channel_event, channel_id, row}` — a host, see `KickTracker.ChannelEvents`
    * `{:chat_messages, channel_id, rows}`, `{:chat_log_event, channel_id, row}`
      — chat logging (§12.8), see `KickTracker.ChatLog`
  """

  alias KickTracker.{Channels, ChatLog, Events, KickUsers, Stats}
  alias KickTracker.Stats.Coverage

  @doc """
  The operation without what it writes for channels that no longer exist
  (deleted while the write waited in the journal): the same operation when
  every channel it names exists, nil when nothing of it is left.
  """
  @spec without_deleted_channels(term()) :: term() | nil
  def without_deleted_channels(op) do
    case channel_ids(op) do
      [] ->
        op

      ids ->
        existing =
          KickTracker.Repo.query!("SELECT id FROM channels WHERE id = ANY($1)", [ids]).rows
          |> MapSet.new(&hd/1)

        if Enum.all?(ids, &MapSet.member?(existing, &1)),
          do: op,
          else: keep_channels(op, existing)
    end
  end

  defp channel_ids({:coverage, ids, _, _, _, _}), do: Enum.uniq(ids)

  defp channel_ids({:subscriber_samples, rows}),
    do: rows |> Enum.map(& &1.channel_id) |> Enum.uniq()

  defp channel_ids({kind, channel_id, _})
       when kind in [:stream, :chat, :channel_event, :chat_messages, :chat_log_event] and
              is_integer(channel_id),
       do: [channel_id]

  defp channel_ids({kind, channel_id, _, _})
       when kind in [:follower_sample, :changes, :chat_stream, :channel_ids, :slug] and
              is_integer(channel_id),
       do: [channel_id]

  defp channel_ids({kind, channel_id, _, _, _, _}) when kind == :viewer_sample, do: [channel_id]
  defp channel_ids(_op), do: []

  defp keep_channels({:coverage, ids, source, ok?, at, gap}, existing) do
    case Enum.filter(ids, &MapSet.member?(existing, &1)) do
      [] -> nil
      kept -> {:coverage, kept, source, ok?, at, gap}
    end
  end

  defp keep_channels({:subscriber_samples, rows}, existing) do
    case Enum.filter(rows, &MapSet.member?(existing, &1.channel_id)) do
      [] -> nil
      kept -> {:subscriber_samples, kept}
    end
  end

  defp keep_channels(_single_channel_op, _existing), do: nil

  @doc "Applies operations in order, in the caller's transaction if any."
  @spec apply_all!([term()]) :: :ok
  def apply_all!(ops), do: Enum.each(ops, &apply!/1)

  @doc "Applies one operation."
  @spec apply!(term()) :: :ok
  def apply!({:stream, channel_id, action}) do
    Stats.apply_stream(channel_id, action)
    :ok
  end

  def apply!({:viewer_sample, channel_id, started_at, at, viewers, category_id}) do
    Stats.insert_viewer_sample(%{
      channel_id: channel_id,
      observed_at: at,
      stream_id: Stats.ensure_stream_id(channel_id, started_at),
      viewers: viewers,
      category_id: category_id
    })
  end

  def apply!({:subscriber_samples, rows}), do: Stats.insert_subscriber_samples(rows)

  def apply!({:follower_sample, channel_id, at, followers}) do
    Stats.insert_samples("follower_samples", [
      %{channel_id: channel_id, observed_at: at, followers: followers}
    ])
  end

  def apply!({:coverage, channel_ids, source, ok?, at, max_gap_s}),
    do: Coverage.mark(channel_ids, source, ok?, at, max_gap_s)

  def apply!({:changes, _channel_id, _started_at, []}), do: :ok

  def apply!({:changes, channel_id, started_at, changes}),
    do: Stats.insert_changes(Stats.ensure_stream_id(channel_id, started_at), changes)

  def apply!({:category, category, at}), do: Stats.upsert_category(category, at)

  def apply!({:chat, channel_id, minutes}) do
    rows =
      for m <- minutes do
        stream_id = m.started_at && Stats.ensure_stream_id(channel_id, m.started_at)
        m |> Map.delete(:started_at) |> Map.put(:stream_id, stream_id)
      end

    Stats.write_chat(channel_id, rows)
  end

  def apply!({:chat_stream, channel_id, started_at, until}) do
    Stats.attribute_chat(channel_id, Stats.ensure_stream_id(channel_id, started_at), until)
  end

  def apply!({:kick_users, users}), do: KickUsers.upsert(users)
  def apply!({:processed, message_ids}), do: Events.mark_processed(message_ids)

  def apply!({:channel_ids, channel_id, kick_channel_id, chatroom_id}) do
    Channels.store_ids(channel_id, kick_channel_id, chatroom_id)
    :ok
  end

  def apply!({:channel_event, channel_id, row}),
    do: Stats.insert_channel_event(Map.put(row, :channel_id, channel_id))

  def apply!({:chat_messages, channel_id, rows}), do: ChatLog.insert_messages(channel_id, rows)
  def apply!({:chat_log_event, channel_id, row}), do: ChatLog.insert_event(channel_id, row)

  def apply!({:slug, channel_id, slug, at}) do
    Channels.store_slug(channel_id, slug, at)
    :ok
  end
end
