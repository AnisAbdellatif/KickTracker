defmodule KickTracker.Tracking.ChannelServer do
  @moduledoc """
  One per tracked channel (project.md §10): the channel's live state and
  every write that depends on it.

  It hears three things: poll readings from the viewers source
  (`{:reading, livestream | :offline, at}`), stream status and metadata
  events from the queue consumer (`{:event, envelope}`), and chat messages
  from its `ChatSocket` (`{:chat, message}`). They go to the pure
  `Sessionizer`, `Changes` and `ChatMinutes`; this process only carries
  their state and records what they decide.

  Every write goes to the collector's journal (`Collector.Ops`), naming
  streams by `(channel, started_at)`, so nothing here waits on Postgres
  or fails with it. Chat is written minute by minute once each minute is
  over, so a crash loses at most the last minute or so.

  On start it loads the channel's recent streams (so a restart mid-stream
  continues the same stream) and then its events still unprocessed. When
  the database can't be read, or when it restarts within the same lease
  term (writes may still be on their way), it starts from the snapshot of
  its state it keeps in the journal instead.

  It starts from the channel's row as it is then (not as it was when the
  channel was first started), and hears later changes to it as the
  changed fields only.

  An event whose handling raises is logged, reported and marked
  processed, so one bad payload can't crash the channel in a loop; it
  stays in `webhook_events` to be replayed once fixed. One that takes the
  process down some other way is set aside after a few starts (see
  `catch_up/2`).
  """

  use GenServer, restart: :permanent
  require Logger

  @flush_every_ms 15_000
  @held_meta_window_s 300
  @max_catch_up_attempts 3

  alias KickTracker.{ChannelEvents, Collector, Events, Stats, Tracking}
  alias KickTracker.Channels.Channel
  alias KickTracker.Collector.{Journal, Tracked}
  alias KickTracker.Collector.Sources.{Followers, Viewers}
  alias KickTracker.Events.Envelope
  alias KickTracker.Metrics.{ChatMinutes, Changes, Sessionizer}

  @spec start_link(Channel.t()) :: GenServer.on_start()
  def start_link(%Channel{} = channel),
    do:
      GenServer.start_link(__MODULE__, channel,
        name: Tracking.via({:channel, channel.kick_user_id})
      )

  @doc "The channel's process, by Kick broadcaster id, or nil."
  @spec whereis(integer()) :: pid() | nil
  def whereis(kick_user_id), do: Tracking.whereis({:channel, kick_user_id})

  @doc "What the process knows, for tests and the health page."
  @spec info(pid() | integer()) :: map()
  def info(pid) when is_pid(pid), do: GenServer.call(pid, :info)
  def info(kick_user_id), do: kick_user_id |> whereis() |> info()

  @doc "PubSub topic for a channel's live readings and stream events."
  @spec topic(integer()) :: String.t()
  def topic(channel_id), do: "channel:#{channel_id}"

  @impl true
  def init(%Channel{} = channel) do
    channel = Tracking.ChannelSup.current(channel)
    # So a shutdown (a deploy) writes the chat gathered so far.
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(KickTracker.PubSub, "channel_row:#{channel.id}")
    Process.send_after(self(), :flush_chat, @flush_every_ms)

    state = %{
      channel: channel,
      sessions: Sessionizer.new(),
      changes: nil,
      changes_for: nil,
      closed_changes: nil,
      pending_meta: nil,
      chat: ChatMinutes.new(),
      unknown_events: MapSet.new()
    }

    {:ok, restore(state), {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state) do
    state =
      case safe(fn -> Events.unprocessed_for(state.channel.kick_user_id) end) do
        {:ok, envelopes} -> catch_up(state, envelopes)
        # They stay unprocessed; `ProcessEvents` hands them over later.
        :error -> state
      end

    {:noreply, state |> snapshot()}
  end

  # Each event handed over at start is counted (in the journal) before it
  # is handled. One that was already tried @max_catch_up_attempts times
  # took the process down each time (an exception is caught and the event
  # marked below; an exit isn't): it is set aside, marked processed and
  # logged, so it can't crash the channel at every start. It stays in
  # `webhook_events` to be replayed once fixed.
  defp catch_up(state, envelopes) do
    key = {:catch_up_attempts, state.channel.id}
    attempts = Journal.get(key) || %{}

    {state, _} =
      Enum.reduce(envelopes, {state, attempts}, fn e, {state, attempts} ->
        tried = Map.get(attempts, e.message_id, 0)

        if tried >= @max_catch_up_attempts do
          Logger.error(
            "event #{e.message_id} for channel #{state.channel.id} stopped the channel " <>
              "#{tried} times, set aside (marked processed)"
          )

          record(state, [{:processed, [e.message_id]}])
          {state, attempts}
        else
          attempts = Map.put(attempts, e.message_id, tried + 1)
          Journal.put(key, attempts)
          {handle_event(state, e), attempts}
        end
      end)

    if attempts != %{} or envelopes != [], do: Journal.put(key, %{})
    state
  end

  @impl true
  def handle_call({:flush_chat, now}, _from, state), do: {:reply, :ok, flush_chat(state, now)}

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       channel: state.channel,
       open_stream: Sessionizer.open_stream(state.sessions),
       streams: Sessionizer.streams(state.sessions)
     }, state}
  end

  @impl true
  def handle_info({:reading, :offline, at}, state) do
    {:noreply, state |> observe({:offline, at}) |> covered(at) |> snapshot()}
  end

  def handle_info({:reading, %{} = livestream, at}, state) do
    {:noreply, state |> reading(livestream, at) |> covered(at) |> snapshot()}
  end

  def handle_info({:event, %Envelope{} = envelope}, state) do
    {:noreply, state |> handle_event(envelope) |> snapshot()}
  end

  def handle_info({:channel_fields, fields}, state) do
    {:noreply, %{state | channel: struct(state.channel, fields)}}
  end

  def handle_info({:chat, message}, state) do
    {:noreply, %{state | chat: ChatMinutes.add(state.chat, message)}}
  end

  # A host, sent or received (project.md §16): kept as sent until real ones
  # show what to parse.
  def handle_info({:pusher_raw, name, pusher_channel, data, at}, state) do
    record(state, [
      {:channel_event, state.channel.id, ChannelEvents.raw(name, pusher_channel, data, at)}
    ])

    {:noreply, state}
  end

  # A chat-feed event we don't know: its name is logged once, its data
  # never kept.
  def handle_info({:pusher_other, name, pusher_channel}, state) do
    if MapSet.member?(state.unknown_events, name) do
      {:noreply, state}
    else
      Logger.info(
        "channel #{state.channel.id}: unknown chat-feed event #{name} on #{pusher_channel}"
      )

      {:noreply, %{state | unknown_events: MapSet.put(state.unknown_events, name)}}
    end
  end

  def handle_info(:flush_chat, state) do
    Process.send_after(self(), :flush_chat, @flush_every_ms)
    {:noreply, flush_chat(state, DateTime.utc_now())}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    # Everything gathered, finished minutes or not.
    flush_chat(state, DateTime.add(DateTime.utc_now(), 3600))
    snapshot(state)
  rescue
    _ -> :ok
  end

  @doc false
  # For tests: write every chat minute over as of `now`.
  def flush_chat_now(pid, now), do: GenServer.call(pid, {:flush_chat, now})

  # --- start -----------------------------------------------------------------

  # Within the same lease term, the snapshot is at least as new as the
  # database (writes may still be in the journal); otherwise the database
  # is the truth, and the snapshot only stands in when it can't be read.
  defp restore(state) do
    id = state.channel.id
    snap = Journal.get({:channel_state, id})

    if snap != nil and snap.epoch == Collector.epoch() and Collector.epoch() != 0 do
      from_snapshot(state, snap)
    else
      case safe(fn -> Stats.recent_streams(id) end) do
        {:ok, rows} ->
          from_database(%{state | sessions: Sessionizer.new(rows)})

        :error when snap != nil ->
          Logger.warning("channel #{id}: database unreachable, starting from its snapshot")
          from_snapshot(state, snap)

        :error ->
          Logger.warning("channel #{id}: database unreachable and no snapshot, starting afresh")
          state
      end
    end
  end

  # The open stream's change log continues from its recorded values.
  defp from_database(state) do
    case Sessionizer.open_stream(state.sessions) do
      nil ->
        state

      started_at ->
        {values, as_of} =
          case safe(fn -> Stats.current_values(state.channel.id, started_at) end) do
            {:ok, found} -> found
            :error -> {nil, nil}
          end

        %{state | changes: Changes.new(values, as_of), changes_for: started_at}
    end
  end

  defp from_snapshot(state, snap) do
    %{
      state
      | sessions: snap.sessions,
        changes: snap.changes,
        changes_for: snap.changes_for,
        closed_changes: Map.get(snap, :closed_changes),
        pending_meta: snap.pending_meta
    }
  end

  # The state worth keeping across a restart, when it changed.
  defp snapshot(state) do
    snap = %{
      epoch: Collector.epoch(),
      sessions: state.sessions,
      changes: state.changes,
      changes_for: state.changes_for,
      closed_changes: state.closed_changes,
      pending_meta: state.pending_meta
    }

    if Process.get(:last_snapshot) != snap do
      Process.put(:last_snapshot, snap)
      Journal.put({:channel_state, state.channel.id}, snap)
    end

    state
  end

  # --- chat ------------------------------------------------------------------

  defp flush_chat(state, now) do
    {minutes, users, chat} = ChatMinutes.take_done(state.chat, now)

    rows =
      for m <- minutes do
        Map.put(
          m,
          :started_at,
          Sessionizer.stream_during(state.sessions, m.minute, DateTime.add(m.minute, 60))
        )
      end

    record(state, [{:chat, state.channel.id, rows}, {:kick_users, users}])

    for m <- rows do
      broadcast(
        state,
        {:chat_minute,
         %{
           minute: m.minute,
           messages: Enum.sum_by(Map.values(m.users), & &1.messages),
           chatters: map_size(m.users)
         }}
      )
    end

    %{state | chat: chat}
  end

  # --- readings ------------------------------------------------------------

  defp reading(state, livestream, at) do
    case parse_time(livestream["started_at"]) do
      nil ->
        Logger.warning("reading without a usable started_at for channel #{state.channel.id}")
        state

      started_at ->
        state = learn_channel_id(state, livestream["channel_id"])
        state = observe(state, {:live, started_at, at})
        {snapshot, category} = Changes.from_livestream(livestream)

        if Sessionizer.sample?(state.sessions, started_at, at) do
          viewers = livestream["viewer_count"]
          category_id = category && category.id

          if is_integer(viewers) and viewers >= 0 do
            record(state, [
              {:category, category, at},
              {:viewer_sample, state.channel.id, Sessionizer.norm(started_at), at, viewers,
               category_id}
            ])

            broadcast(state, {:viewers, %{at: at, viewers: viewers, category_id: category_id}})
          else
            record(state, [{:category, category, at}])
          end
        end

        if Sessionizer.open_stream(state.sessions) == Sessionizer.norm(started_at),
          do: track_changes(state, :poll, snapshot, at),
          else: state
    end
  end

  # The viewers poll's coverage, for this channel: recorded here, once the
  # reading is handled, so a reading that no process was there to handle
  # (restarting, stopped) stays a gap (AGENTS.md §7).
  defp covered(state, at) do
    {source, gap_s} = Viewers.coverage()
    record(state, [{:coverage, [state.channel.id], source, true, at, gap_s}])
    state
  end

  # The livestream carries Kick's channel id, which the chat feed's
  # per-channel topic uses.
  # Only that field is passed on: this process's copy of the row may be
  # older than what others learnt meanwhile (a chatroom id).
  defp learn_channel_id(%{channel: %{kick_channel_id: nil} = channel} = state, id)
       when is_integer(id) do
    record(state, [{:channel_ids, channel.id, id, nil}])
    Tracked.update(channel.id, kick_channel_id: id)
    KickTracker.Channels.announce(channel.id, %{kick_channel_id: id})
    %{state | channel: %{channel | kick_channel_id: id}}
  end

  defp learn_channel_id(state, _id), do: state

  # --- events --------------------------------------------------------------

  defp handle_event(state, %Envelope{} = envelope) do
    state =
      try do
        case Envelope.payload(envelope) do
          {:ok, body} ->
            event(state, envelope.event_type, body, envelope.occurred_at)

          {:error, _} ->
            Logger.error("event #{envelope.message_id} has an unreadable body")
            state
        end
      rescue
        error ->
          Logger.error(
            "event #{envelope.message_id} for channel #{state.channel.id} could not be handled, skipped: " <>
              Exception.format(:error, error, __STACKTRACE__)
          )

          ErrorTracker.report(error, __STACKTRACE__, %{message_id: envelope.message_id})
          state
      end

    record(state, [{:processed, [envelope.message_id]}])
    state
  end

  defp event(state, "livestream.status.updated", body, occurred_at) do
    started_at = parse_time(body["started_at"])
    ended_at = parse_time(body["ended_at"])

    cond do
      started_at == nil -> state
      body["is_live"] == true -> observe(state, {:live, started_at, occurred_at})
      ended_at != nil -> observe(state, {:ended, started_at, ended_at})
      true -> state
    end
  end

  defp event(state, "livestream.metadata.updated", body, occurred_at) do
    {snapshot, category} = Changes.from_event(body)
    record(state, [{:category, category, occurred_at}])

    case Sessionizer.open_stream(state.sessions) do
      nil ->
        # No stream open (yet): the status event may still be on its way.
        # Keep the latest snapshot for the stream that opens next.
        if state.pending_meta == nil or
             DateTime.after?(occurred_at, elem(state.pending_meta, 1)),
           do: %{state | pending_meta: {snapshot, occurred_at}},
           else: state

      started_at ->
        if DateTime.before?(occurred_at, started_at),
          do: state,
          else: track_changes(state, :event, snapshot, occurred_at)
    end
  end

  defp event(state, _other, _body, _at), do: state

  # --- stream state ----------------------------------------------------------

  defp observe(state, observation) do
    before = Sessionizer.open_stream(state.sessions)
    {sessions, actions} = Sessionizer.apply(state.sessions, observation)
    record(state, Enum.map(actions, &{:stream, state.channel.id, &1}))

    state = %{state | sessions: sessions}
    Enum.each(actions, &announce(state, &1))

    case Sessionizer.open_stream(sessions) do
      ^before ->
        state

      nil ->
        # Kept: a stream closed from polling may reopen, and its change log
        # then continues where it was.
        %{
          state
          | changes: nil,
            changes_for: nil,
            closed_changes: {state.changes_for, state.changes}
        }

      opened ->
        attribute_chat(state, opened)
        start_changes(state, opened, {:reopen, opened} in actions)
    end
  end

  # Chat written before this stream was known here (its start learnt
  # late: a missed start event, the API's lag) was written with no stream;
  # it is the stream's (project.md §12.3). Attributed in the database, as
  # a journaled write like every other.
  defp attribute_chat(state, started_at) do
    record(state, [
      {:chat_stream, state.channel.id, started_at, Sessionizer.norm(DateTime.utc_now())}
    ])
  end

  # A follower reading at each stream's start and end gives its exact
  # follower gain (§3.1). Only for ends that just happened: replaying an
  # old event must not trigger a reading now.
  defp announce(state, {:open, started_at}) do
    Followers.request(state.channel.id, :stream_start)
    broadcast(state, {:stream_started, started_at})
  end

  defp announce(state, {:reopen, started_at}),
    do: broadcast(state, {:stream_started, started_at})

  defp announce(state, {:close, started_at, ended_at, _source}) do
    if DateTime.diff(DateTime.utc_now(), ended_at) < 600,
      do: Followers.request(state.channel.id, :stream_end)

    broadcast(state, {:stream_ended, started_at, ended_at})
  end

  # A stream just became the open one: start its change log, with any
  # metadata that arrived shortly before its status event. A stream closed
  # from polling that reopens continues its own log (from memory, else
  # from the database), so its values aren't recorded again as new.
  defp start_changes(state, started_at, reopened?) do
    state =
      cond do
        state.changes_for == started_at ->
          state

        match?({^started_at, %Changes{}}, state.closed_changes) ->
          %{state | changes: elem(state.closed_changes, 1), changes_for: started_at}

        reopened? ->
          {values, as_of} =
            case safe(fn -> Stats.current_values(state.channel.id, started_at) end) do
              {:ok, found} -> found
              :error -> {nil, nil}
            end

          %{state | changes: Changes.new(values, as_of), changes_for: started_at}

        true ->
          %{state | changes: Changes.new(), changes_for: started_at}
      end

    state = %{state | closed_changes: nil}

    case state.pending_meta do
      {snapshot, at} ->
        state = %{state | pending_meta: nil}

        if held_meta_applies?(at, started_at) do
          at = if DateTime.before?(at, started_at), do: started_at, else: at
          track_changes(state, :event, snapshot, at)
        else
          # Older than any status event could precede its stream by: it
          # described an earlier stream, or none. Dropped, nothing written.
          Logger.info(
            "channel #{state.channel.id}: metadata from #{at} dropped, too old for the stream started #{started_at}"
          )

          state
        end

      nil ->
        state
    end
  end

  @doc false
  # Metadata held while no stream was open goes to the stream that opens
  # next only if it came at most this long before that stream's start (or
  # after it).
  def held_meta_window_s, do: @held_meta_window_s

  defp held_meta_applies?(at, started_at),
    do: DateTime.diff(started_at, at) <= @held_meta_window_s

  defp track_changes(state, source, snapshot, at) do
    tracker = state.changes || Changes.new()

    {tracker, changes} =
      case source do
        :event -> Changes.event(tracker, snapshot, at)
        :poll -> Changes.poll(tracker, snapshot, at)
      end

    if changes != [] do
      record(state, [{:changes, state.channel.id, state.changes_for, changes}])
      broadcast(state, {:changes, changes})
    end

    %{state | changes: tracker}
  end

  defp record(_state, ops), do: Journal.append(ops)

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(KickTracker.PubSub, topic(state.channel.id), message)
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("database read failed: #{Exception.message(error)}")
      :error
  catch
    :exit, _ -> :error
  end

  # Kick's timestamps: `...Z`, whole seconds. An offline channel's zero
  # time (`0001-01-01T00:00:00Z`) means "none".
  defp parse_time(nil), do: nil
  defp parse_time("0001-01-01" <> _), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> Sessionizer.norm(at)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
