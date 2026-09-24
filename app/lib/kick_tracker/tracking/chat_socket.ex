defmodule KickTracker.Tracking.ChatSocket do
  @moduledoc """
  One channel's connection to Kick's chat feed (Pusher, project.md §2.4,
  §10).

  Subscribes to the chatroom (and to the channel's own topic once its id is
  known, where raids and hosts may appear), answers pings, pings when the
  line has been quiet for Pusher's activity timeout, and hands each
  message's sender and time to the `ChannelServer`. No text is kept.

  It reconnects on its own with backoff (1s doubling to 30s), and records
  in `coverage` (source `chat`) when chat was being received and when not,
  so per-minute chat counts can say how complete they are. Chat is
  optional: while this is down, everything else keeps collecting.

  Until the channel's chatroom id is known (learnt from v2 by the first
  follower reading), it waits.
  """

  use GenServer
  require Logger

  alias KickTracker.Channels.Channel
  alias KickTracker.Kick.Pusher
  alias KickTracker.Stats.Coverage
  alias KickTracker.Tracking.ChannelServer

  @max_backoff_ms 30_000
  @coverage_every_ms 60_000
  @coverage_gap_s 150
  @pong_timeout_s 30

  @spec start_link(Channel.t()) :: GenServer.on_start()
  def start_link(%Channel{} = channel),
    do:
      GenServer.start_link(__MODULE__, channel,
        name: KickTracker.Tracking.via({:chat, channel.id})
      )

  @doc "Whether the chatroom subscription is live. For tests and the health page."
  @spec subscribed?(pid()) :: boolean()
  def subscribed?(pid), do: GenServer.call(pid, :subscribed?)

  @impl true
  def init(%Channel{} = channel) do
    Phoenix.PubSub.subscribe(KickTracker.PubSub, "channel_row:#{channel.id}")
    send(self(), :connect)
    Process.send_after(self(), :coverage, @coverage_every_ms)

    {:ok,
     %{
       channel: channel,
       conn: nil,
       ref: nil,
       ws: nil,
       upgrade: %{},
       subscribed: MapSet.new(),
       backoff_ms: 1_000,
       activity_timeout_s: 120,
       last_in: now_s(),
       ping_sent_at: nil,
       timer: nil,
       activity_timer: nil
     }}
  end

  @impl true
  def handle_call(:subscribed?, _from, state),
    do: {:reply, MapSet.member?(state.subscribed, chatroom_topic(state)), state}

  @impl true
  def handle_info(:connect, %{channel: %{chatroom_id: nil}} = state) do
    # Not known yet; the row update that brings it reconnects at once.
    {:noreply, schedule(state, :connect, 60_000)}
  end

  def handle_info(:connect, state) do
    state = %{state | timer: nil}
    url = URI.parse(Application.fetch_env!(:kick_tracker, :kick)[:pusher_url])
    {http, ws} = if url.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    path = (url.path || "/") <> if(url.query, do: "?" <> url.query, else: "")

    with {:ok, conn} <- Mint.HTTP.connect(http, url.host, url.port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws, conn, path, KickTracker.Kick.UserAgent.headers()) do
      {:noreply, %{state | conn: conn, ref: ref, ws: nil, upgrade: %{}, last_in: now_s()}}
    else
      {:error, reason} -> {:noreply, reconnect(state, reason)}
      {:error, _conn, reason} -> {:noreply, reconnect(state, reason)}
    end
  end

  def handle_info({:channel, %Channel{} = channel}, state) do
    old = state.channel
    state = %{state | channel: channel}

    cond do
      # Just learnt where to connect.
      old.chatroom_id == nil and channel.chatroom_id != nil and state.conn == nil ->
        {:noreply, cancel_timer(state) |> tap(fn _ -> send(self(), :connect) end)}

      # Just learnt the channel's own topic: add it.
      old.kick_channel_id == nil and channel.kick_channel_id != nil and state.ws != nil ->
        {:noreply, send_text(state, Pusher.subscribe(Pusher.channel(channel.kick_channel_id)))}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:coverage, state) do
    Process.send_after(self(), :coverage, @coverage_every_ms)
    if MapSet.member?(state.subscribed, chatroom_topic(state)), do: mark(state, true)
    {:noreply, state}
  end

  # Quiet line: ping, and give up on the connection if no answer comes.
  def handle_info(:activity, %{ws: nil} = state), do: {:noreply, state}

  def handle_info(:activity, state) do
    state = %{state | activity_timer: Process.send_after(self(), :activity, 10_000)}
    quiet = now_s() - state.last_in

    cond do
      state.ping_sent_at && now_s() - state.ping_sent_at > @pong_timeout_s ->
        {:noreply, reconnect(state, :pong_timeout)}

      quiet >= state.activity_timeout_s and state.ping_sent_at == nil ->
        {:noreply, %{send_text(state, Pusher.ping()) | ping_sent_at: now_s()}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> {:noreply, handle_responses(%{state | conn: conn}, responses)}
      {:error, conn, reason, _} -> {:noreply, reconnect(%{state | conn: conn}, reason)}
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # --- the connection ----------------------------------------------------------

  # Until the upgrade is done, responses are the HTTP answer; the first
  # websocket frames can arrive in the same read as the 101 (seen on the
  # real Kick), so whatever follows `:done` is decoded too.
  defp handle_responses(%{ws: nil, ref: ref} = state, responses) do
    {upgrade, rest} = Enum.split_while(responses, &(not match?({:done, ^ref}, &1)))

    acc =
      Enum.reduce(upgrade, state.upgrade, fn
        {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
        {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
        {:data, ^ref, data}, acc -> Map.update(acc, :data, [data], &[data | &1])
        _, acc -> acc
      end)

    case rest do
      [] ->
        %{state | upgrade: acc}

      [{:done, ^ref} | leftover] ->
        case Mint.WebSocket.new(state.conn, ref, acc[:status], acc[:headers] || []) do
          {:ok, conn, ws} ->
            early = acc |> Map.get(:data, []) |> Enum.reverse() |> Enum.map(&{:data, ref, &1})
            timer = Process.send_after(self(), :activity, 10_000)
            state = %{state | conn: conn, ws: ws, upgrade: %{}, activity_timer: timer}
            handle_responses(state, early ++ leftover)

          {:error, conn, reason} ->
            reconnect(%{state | conn: conn}, reason)
        end
    end
  end

  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, fn
      {:data, ref, data}, %{ref: ref, ws: ws} = state when ws != nil ->
        case Mint.WebSocket.decode(ws, data) do
          {:ok, ws, frames} -> Enum.reduce(frames, %{state | ws: ws}, &frame/2)
          {:error, ws, reason} -> reconnect(%{state | ws: ws}, reason)
        end

      _, state ->
        state
    end)
  end

  defp frame(_frame, %{conn: nil} = state), do: state

  defp frame({:text, text}, state) do
    state = %{state | last_in: now_s()}

    case Pusher.decode(text) do
      {:connected, timeout} ->
        state = %{state | activity_timeout_s: timeout}
        Enum.reduce(topics(state), state, &send_text(&2, Pusher.subscribe(&1)))

      {:subscribed, topic} ->
        state = %{state | subscribed: MapSet.put(state.subscribed, topic), backoff_ms: 1_000}
        if topic == chatroom_topic(state), do: mark(state, true)
        state

      :ping ->
        send_text(state, Pusher.pong())

      :pong ->
        %{state | ping_sent_at: nil}

      {:chat, message} ->
        to_channel(state, {:chat, message})
        state

      {:error, code, message} ->
        Logger.warning("chat feed error for channel #{state.channel.id}: #{code} #{message}")
        state

      {:other, name, topic} ->
        to_channel(state, {:pusher_other, name, topic})
        state

      :invalid ->
        state
    end
  end

  defp frame({:ping, data}, state), do: send_frame(%{state | last_in: now_s()}, {:pong, data})
  defp frame({:close, code, reason}, state), do: reconnect(state, {:closed, code, reason})
  defp frame(_other, state), do: %{state | last_in: now_s()}

  defp topics(state) do
    [chatroom_topic(state)] ++
      if state.channel.kick_channel_id,
        do: [Pusher.channel(state.channel.kick_channel_id)],
        else: []
  end

  defp chatroom_topic(%{channel: %{chatroom_id: nil}}), do: nil
  defp chatroom_topic(state), do: Pusher.chatroom(state.channel.chatroom_id)

  defp to_channel(state, message) do
    if pid = ChannelServer.whereis(state.channel.kick_user_id), do: send(pid, message)
  end

  defp send_text(state, text), do: send_frame(state, {:text, text})

  defp send_frame(%{ws: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | ws: ws, conn: conn}
    else
      {:error, %Mint.WebSocket{} = ws, reason} -> reconnect(%{state | ws: ws}, reason)
      {:error, conn, reason} -> reconnect(%{state | conn: conn}, reason)
    end
  end

  # Drop the connection, record the gap, try again after the backoff.
  defp reconnect(%{conn: nil, timer: timer} = state, _reason) when timer != nil, do: state

  defp reconnect(state, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.activity_timer, do: Process.cancel_timer(state.activity_timer)
    was_subscribed = MapSet.member?(state.subscribed, chatroom_topic(state))
    if was_subscribed, do: mark(state, false)

    Logger.info(
      "chat feed for channel #{state.channel.id} disconnected (#{inspect(reason)}), retrying in #{state.backoff_ms}ms"
    )

    %{
      state
      | conn: nil,
        ref: nil,
        ws: nil,
        upgrade: %{},
        subscribed: MapSet.new(),
        ping_sent_at: nil,
        activity_timer: nil,
        backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)
    }
    |> cancel_timer()
    |> schedule(:connect, state.backoff_ms)
  end

  defp schedule(state, message, ms), do: %{state | timer: Process.send_after(self(), message, ms)}

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp mark(state, ok?) do
    Coverage.mark(
      [state.channel.id],
      "chat",
      ok?,
      KickTracker.Metrics.Sessionizer.norm(DateTime.utc_now()),
      @coverage_gap_s
    )
  rescue
    # Coverage is bookkeeping: a database hiccup must not drop the socket.
    error -> Logger.warning("could not record chat coverage: #{Exception.message(error)}")
  end

  defp now_s, do: System.monotonic_time(:second)
end
