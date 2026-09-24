defmodule KickTracker.Tracking.ChannelServer do
  @moduledoc """
  One per tracked channel (project.md §10): the channel's live state and
  every write that depends on it.

  It hears two things: poll readings from `KickTracker.Tracking.Poller`
  (`{:reading, livestream | :offline, at}`) and stream status and metadata
  events from the queue consumer (`{:event, envelope}`). Both become
  observations for the pure `Sessionizer` and `Changes`; this process
  only carries their state and writes what they decide.

  On start it reloads the channel's recent streams (so a restart mid-stream
  continues the same stream) and then handles its channel's events still
  unprocessed in the database. A crash loses at most the reading in hand,
  which is a gap, never a zero; an event in hand stays unprocessed and is
  handled on restart.
  """

  use GenServer, restart: :permanent
  require Logger

  alias KickTracker.{Events, Stats, Tracking}
  alias KickTracker.Channels.Channel
  alias KickTracker.Events.Envelope
  alias KickTracker.Metrics.{Changes, Sessionizer}

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
    rows = Stats.recent_streams(channel.id)
    sessions = Sessionizer.new(rows)
    ids = Map.new(rows, &{Sessionizer.norm(&1.started_at), &1.id})

    state = %{
      channel: channel,
      sessions: sessions,
      ids: ids,
      changes: nil,
      changes_for: nil,
      pending_meta: nil
    }

    {:ok, restore_changes(state), {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state) do
    state =
      state.channel.kick_user_id
      |> Events.unprocessed_for()
      |> Enum.reduce(state, &handle_event(&2, &1))

    {:noreply, state}
  end

  @impl true
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
    {:noreply, observe(state, {:offline, at})}
  end

  def handle_info({:reading, %{} = livestream, at}, state) do
    {:noreply, reading(state, livestream, at)}
  end

  def handle_info({:event, %Envelope{} = envelope}, state) do
    {:noreply, handle_event(state, envelope)}
  end

  def handle_info({:channel, %Channel{} = channel}, state) do
    {:noreply, %{state | channel: channel}}
  end

  # --- readings ------------------------------------------------------------

  defp reading(state, livestream, at) do
    case parse_time(livestream["started_at"]) do
      nil ->
        Logger.warning("reading without a usable started_at for channel #{state.channel.id}")
        state

      started_at ->
        state = observe(state, {:live, started_at, at})
        {snapshot, category} = Changes.from_livestream(livestream)

        if Sessionizer.sample?(state.sessions, started_at, at) do
          stream_id = Map.fetch!(state.ids, Sessionizer.norm(started_at))
          viewers = livestream["viewer_count"]
          category_id = category && category.id
          Stats.upsert_category(category, at)

          if is_integer(viewers) and viewers >= 0 do
            Stats.insert_viewer_sample(%{
              channel_id: state.channel.id,
              observed_at: at,
              stream_id: stream_id,
              viewers: viewers,
              category_id: category_id
            })

            broadcast(state, {:viewers, %{at: at, viewers: viewers, category_id: category_id}})
          end
        end

        if Sessionizer.open_stream(state.sessions) == Sessionizer.norm(started_at),
          do: track_changes(state, :poll, snapshot, at),
          else: state
    end
  end

  # --- events --------------------------------------------------------------

  defp handle_event(state, %Envelope{} = envelope) do
    state =
      case Envelope.payload(envelope) do
        {:ok, body} ->
          event(state, envelope.event_type, body, envelope.occurred_at)

        {:error, _} ->
          Logger.error("event #{envelope.message_id} has an unreadable body")
          state
      end

    Events.mark_processed([envelope.message_id])
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
    Stats.upsert_category(category, occurred_at)

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

    ids =
      Enum.reduce(actions, state.ids, fn action, ids ->
        id = Stats.apply_stream(state.channel.id, action)
        Map.put(ids, elem(action, 1), id)
      end)

    state = %{state | sessions: sessions, ids: ids}
    Enum.each(actions, &announce(state, &1))

    case Sessionizer.open_stream(sessions) do
      ^before -> state
      nil -> %{state | changes: nil, changes_for: nil}
      opened -> start_changes(state, opened)
    end
  end

  defp announce(state, {:open, started_at}),
    do: broadcast(state, {:stream_started, started_at})

  defp announce(state, {:reopen, started_at}),
    do: broadcast(state, {:stream_started, started_at})

  defp announce(state, {:close, started_at, ended_at, _source}),
    do: broadcast(state, {:stream_ended, started_at, ended_at})

  # A stream just became the open one: start its change log, with any
  # metadata that arrived before its status event.
  defp start_changes(state, started_at) do
    state =
      if state.changes_for == started_at,
        do: state,
        else: %{state | changes: Changes.new(), changes_for: started_at}

    case state.pending_meta do
      {snapshot, at} ->
        state = %{state | pending_meta: nil}
        at = if DateTime.before?(at, started_at), do: started_at, else: at
        track_changes(state, :event, snapshot, at)

      nil ->
        state
    end
  end

  defp track_changes(state, source, snapshot, at) do
    tracker = state.changes || Changes.new()

    {tracker, changes} =
      case source do
        :event -> Changes.event(tracker, snapshot, at)
        :poll -> Changes.poll(tracker, snapshot, at)
      end

    stream_id = Map.fetch!(state.ids, state.changes_for)
    Stats.insert_changes(stream_id, changes)
    if changes != [], do: broadcast(state, {:changes, changes})
    %{state | changes: tracker}
  end

  defp restore_changes(state) do
    case Sessionizer.open_stream(state.sessions) do
      nil ->
        state

      started_at ->
        {values, as_of} = Stats.current_values(Map.fetch!(state.ids, started_at))
        %{state | changes: Changes.new(values, as_of), changes_for: started_at}
    end
  end

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(KickTracker.PubSub, topic(state.channel.id), message)
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
