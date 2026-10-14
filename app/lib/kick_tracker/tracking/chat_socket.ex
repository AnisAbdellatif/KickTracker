defmodule KickTracker.Tracking.ChatSocket do
  @moduledoc """
  One channel's connection to Kick's chat feed (Kick's realtime server,
  Centrifugo since 2026-10-13; project.md §2.4, §10).

  kicksdk knows the protocol (KICK.md): this process asks where the
  channel's chat is served and for a guest token (`Kicksdk.Realtime`, sent
  with Req), opens the websocket with the Origin Kick requires, and drives
  a `Kicksdk.Realtime.Session` with what arrives, doing what it says: send
  a frame, refresh the token, close, hand an event on. The session answers
  Kick's pings and says when the line has gone quiet.

  It subscribes to the feeds kicksdk lists for the chatroom (and for the
  channel once its id is known, where hosts leaving appear), and hands
  each message's sender and time to the `ChannelServer`. No text is kept.

  A connection that doesn't complete its upgrade within 15s is dropped
  and retried, like any other failure.

  It reconnects on its own, never giving up, each time as a new client (a
  new client id, so a new guest token and connection request). An
  ordinary drop waits with backoff (1s doubling to 30s, with jitter so
  sockets dropped together don't come back together); that backoff only
  resets once a connection has stayed up for a minute, so a server that
  accepts and then drops at once isn't retried every second. A terminal
  close (Kick doesn't want this client back as it was: a refused token, a
  limit, a ban; a session `close` that says so, or a socket close code
  kicksdk says it of) waits what kicksdk's `Kicksdk.Realtime.Backoff`
  says, 5 minutes, then 10, 20 and 30 for terminal closes in a row, each
  plus up to a quarter; the chat feed subscribing ends the streak (KICK.md
  §6.1). It records
  in `coverage` (source `chat`) when chat was being received and when not,
  so per-minute chat counts can say how complete they are: "not" at once,
  "received" through the `ChannelServer`, which writes it with the counts
  it vouches for (`{:chat_covered, at, max_gap_s}`). Chat is
  optional: while this is down, everything else keeps collecting.

  Until the channel's chatroom id is known (learnt from v2 by the first
  follower reading), it waits. It starts from the channel's row as it is
  then (`ChannelSup.current/1`), and follows changes to it: a chatroom id
  that changed, or a channel id learnt, connects again with the feeds that
  go with it (a session subscribes once, when it connects).
  """

  use GenServer
  require Logger

  alias KickTracker.Channels.Channel
  alias KickTracker.Collector.Journal
  alias KickTracker.Kick.{Endpoints, HTTP, UserAgent}
  alias KickTracker.Tracking.ChannelServer
  alias Kicksdk.Realtime
  alias Kicksdk.Realtime.{Backoff, Session}

  @max_backoff_ms 30_000
  @coverage_every_ms 60_000
  @coverage_gap_s 150
  @connect_timeout_ms 15_000
  @stable_ms 60_000

  @chat_message "App\\Events\\ChatMessageEvent"
  # Hosts (Kick's raids), kept as sent for their channel's `channel_events`
  # (KICK.md §6.3).
  @raw ["App\\Events\\StreamHostEvent", "App\\Events\\ChatMoveToSupportedChannelEvent"]

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
    # Stopped (its channel restarting or removed, a deploy) between two
    # messages, never in the middle of one: a coverage write under way
    # finishes, and the connection is closed properly in `terminate/2`.
    Process.flag(:trap_exit, true)
    channel = KickTracker.Tracking.ChannelSup.current(channel)
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
       # The connection's client id, and its first token until the session
       # opens with it; the session, and the feeds it subscribes to.
       client_id: nil,
       token: nil,
       session: nil,
       feeds: [],
       backoff_ms: 1_000,
       # kicksdk's backoff, for terminal closes only: the streak of them.
       terminal_backoff: Backoff.new(),
       subscribed_at: nil,
       timer: nil,
       tick_at: nil
     }}
  end

  @impl true
  def handle_call(:subscribed?, _from, state), do: {:reply, listening?(state), state}

  @impl true
  def handle_info(:connect, %{channel: %{chatroom_id: nil}} = state) do
    # Not known yet; the row update that brings it reconnects at once.
    {:noreply, schedule(state, :connect, 60_000)}
  end

  def handle_info(:connect, state) do
    state = %{state | timer: nil}
    client_id = Ecto.UUID.generate()
    endpoints = Endpoints.get()
    feeds = Realtime.chat_channels(state.channel.chatroom_id, state.channel.kick_channel_id)

    with {:ok, url} <- server(state.channel, client_id, endpoints),
         {:ok, token} <- token(client_id, endpoints),
         {:ok, conn, ref} <- open(URI.parse(url)) do
      timeout = KickTracker.Collector.config(:chat_connect_timeout_ms, @connect_timeout_ms)
      Process.send_after(self(), {:connect_timeout, ref}, timeout)

      {:noreply,
       %{
         state
         | conn: conn,
           ref: ref,
           ws: nil,
           upgrade: %{},
           client_id: client_id,
           token: token,
           feeds: feeds
       }}
    else
      {:error, reason} -> {:noreply, reconnect(state, reason)}
    end
  end

  def handle_info({:channel_fields, fields}, state) do
    old = state.channel
    channel = struct(old, fields)
    state = %{state | channel: channel}

    cond do
      # Just learnt where to connect.
      old.chatroom_id == nil and channel.chatroom_id != nil and state.conn == nil ->
        {:noreply, cancel_timer(state) |> tap(fn _ -> send(self(), :connect) end)}

      # The chatroom changed: the subscription is to the wrong room. Drop
      # it (recording the gap under the old room) and connect again now.
      old.chatroom_id != nil and channel.chatroom_id != old.chatroom_id ->
        {:noreply, again(state, old, :chatroom_changed)}

      # Just learnt the channel's id: its feeds join the subscription,
      # which a connection can't add to. Connect again now, through the
      # channel's own server.
      old.kick_channel_id == nil and channel.kick_channel_id != nil and state.conn != nil ->
        {:noreply, again(state, old, :channel_id_learnt)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:coverage, state) do
    Process.send_after(self(), :coverage, @coverage_every_ms)
    if listening?(state), do: mark(state, true)
    {:noreply, state}
  end

  # The upgrade never completed: start over.
  def handle_info({:connect_timeout, ref}, %{ref: ref, ws: nil, conn: conn} = state)
      when conn != nil,
      do: {:noreply, reconnect(state, :connect_timeout)}

  def handle_info({:connect_timeout, _ref}, state), do: {:noreply, state}

  # The session's clock: a quiet line, a token to refresh.
  def handle_info(:tick, %{session: nil} = state), do: {:noreply, %{state | tick_at: nil}}

  def handle_info(:tick, state) do
    state = %{state | tick_at: nil}
    {:noreply, act(state, Session.tick(state.session, now_ms()))}
  end

  # Trapping exits: a linked process going down still takes this one down
  # (its supervisor's exit is handled by GenServer itself). A socket port
  # closing is news the connection's own messages already carry.
  def handle_info({:EXIT, pid, reason}, state) when is_pid(pid), do: {:stop, reason, state}
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

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

  # Where the chat is served: the channel's own server once its id is
  # known, else Kick's general one (which carries every channel's chat).
  defp server(channel, client_id, endpoints) do
    request =
      if channel.kick_channel_id,
        do: Realtime.chat_connection_request(channel.kick_channel_id, client_id, endpoints),
        else: Realtime.connection_request(client_id, endpoints)

    with {:ok, status, body} <- HTTP.send(request, receive_timeout: 10_000),
         {:ok, connections} <- Realtime.parse_connection(status, body) do
      case Enum.find(connections, &(&1["provider"] == "centrifugo")) do
        %{"url" => url} when is_binary(url) -> {:ok, url}
        _ -> {:error, :no_centrifugo_server}
      end
    end
  end

  # A guest token for this client id; a refresh asks for the same id.
  defp token(client_id, endpoints) do
    with {:ok, status, body} <-
           HTTP.send(Realtime.token_request(client_id, endpoints), receive_timeout: 10_000) do
      Realtime.parse_token(status, body)
    end
  end

  # Kick refuses a handshake whose Origin isn't kick.com's.
  defp open(%URI{} = url) do
    {http, ws} = if url.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    path = (url.path || "/") <> if(url.query, do: "?" <> url.query, else: "")
    headers = [{"origin", Realtime.required_origin()} | UserAgent.headers()]

    with {:ok, conn} <-
           Mint.HTTP.connect(http, url.host, url.port,
             protocols: [:http1],
             transport_opts: [timeout: 10_000]
           ) do
      case Mint.WebSocket.upgrade(ws, conn, path, headers) do
        {:ok, conn, ref} ->
          {:ok, conn, ref}

        # Connected, but the upgrade request couldn't be sent: the
        # connection is ours to close.
        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason}
      end
    end
  end

  # Until the upgrade is done, responses are the HTTP answer; the first
  # websocket frames can arrive in the same read as the 101 (seen on the
  # real Kick), so whatever follows `:done` is decoded too, once the
  # session is open.
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
            session = Session.new(state.feeds)
            token = state.token
            state = %{state | conn: conn, ws: ws, upgrade: %{}, session: session, token: nil}
            state = act(state, Session.open(session, token, now_ms()))
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
  defp frame({:text, text}, state), do: act(state, Session.receive(state.session, text, now_ms()))
  defp frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp frame({:close, code, reason}, state), do: reconnect(state, {:closed, code, reason})
  defp frame(_other, state), do: state

  # What the session says to do, in order. A close ends the connection:
  # what came after it in the same list is moot.
  defp act(state, actions) do
    actions
    |> Enum.reduce(state, fn
      _action, %{session: nil} = state -> state
      action, state -> action(state, action)
    end)
    |> schedule_tick()
  end

  defp action(state, %{"action" => "send", "text" => text}), do: send_frame(state, {:text, text})

  defp action(state, %{"action" => "close"} = close), do: reconnect(state, {:kick, close})

  defp action(state, %{"action" => "refresh_token"}), do: refresh(state)

  defp action(state, %{"action" => "subscribed", "channel" => feed}) do
    if feed == chat_feed(state) do
      mark(state, true)

      %{
        state
        | subscribed_at: System.monotonic_time(:millisecond),
          terminal_backoff: Backoff.reset(state.terminal_backoff)
      }
    else
      state
    end
  end

  # Kick took the chat feed away, or refused it: no chat comes on this
  # connection, and the gap is recorded now (the session no longer counts
  # the feed as subscribed). With a code from 2500 to 2999 Kick asks for a
  # new subscribe, which the session has already sent: "subscribed" or
  # "subscribe_failed" follows. Another feed refused is only worth a line.
  defp action(state, %{"action" => action, "channel" => feed} = a)
       when action in ["unsubscribed", "subscribe_failed"] do
    why = {a["code"], a["reason"] || a["message"]}

    cond do
      feed != chat_feed(state) ->
        Logger.info(
          "chat feed for channel #{state.channel.id}: #{feed} #{action} #{inspect(why)}"
        )

        state

      action == "unsubscribed" and a["code"] in 2500..2999 ->
        Logger.info(
          "chat feed for channel #{state.channel.id}: subscribing again (#{inspect(why)})"
        )

        mark(state, false)
        %{state | subscribed_at: nil}

      action == "unsubscribed" ->
        mark(state, false)
        reconnect(state, {:unsubscribed, why})

      true ->
        reconnect(state, {:subscribe_failed, why})
    end
  end

  defp action(state, %{"action" => "event"} = event), do: event(state, event)
  defp action(state, _connected), do: state

  # If no new token can be had, nothing: Kick ends the connection when the
  # old one runs out, and the reconnect gets a new one.
  defp refresh(state) do
    case token(state.client_id, Endpoints.get()) do
      {:ok, token} ->
        Session.refresh(state.session, token, now_ms())
        |> Enum.reduce(state, fn
          _action, %{session: nil} = state -> state
          action, state -> action(state, action)
        end)

      {:error, reason} ->
        Logger.warning(
          "chat feed for channel #{state.channel.id}: no new token (#{inspect(reason)})"
        )

        state
    end
  end

  # --- events -----------------------------------------------------------------

  # A chat message on the chatroom's chat feed, read by kicksdk. One that
  # can't be counted (no sender id or time) is dropped.
  defp event(state, %{"name" => @chat_message, "channel" => feed, "event" => message} = event) do
    if feed == chat_feed(state) do
      case chat(message) do
        {:ok, counted, text} -> forward(state, {:chat, counted, text})
        :invalid -> state
      end
    else
      other(state, event)
    end
  end

  defp event(state, %{"name" => name, "channel" => feed, "data" => data}) when name in @raw do
    to_channel(state, {:pusher_raw, name, feed, data(data), DateTime.utc_now()})
    state
  end

  defp event(state, event), do: other(state, event)

  defp other(state, %{"name" => name, "channel" => feed, "data" => data}),
    do: forward(state, {:other, name, feed, data(data)})

  # The counted part (sender, message id, time), which is all that goes
  # further for most channels, and the text and reply target, which only a
  # channel with chat logging on keeps (§12.8, AGENTS.md §7). Chat times
  # end in `+00:00`, not `Z`.
  defp chat(%{"type" => "chat_message"} = m) do
    with %{"id" => sender_id} = sender when is_integer(sender_id) <- m["sender"],
         created_at when is_binary(created_at) <- m["created_at"],
         {:ok, at, _} <- DateTime.from_iso8601(created_at) do
      reply = m["reply_to"] || %{}

      {:ok,
       %{
         id: m["id"],
         sender_id: sender_id,
         username: sender["username"],
         at: KickTracker.Metrics.Sessionizer.norm(at)
       },
       %{
         content: string(m["content"]),
         type: string(m["kind"]),
         reply_to_message_id: string(reply["message_id"]),
         reply_to_user_id: integer(reply["sender_id"])
       }}
    else
      _ -> :invalid
    end
  end

  defp chat(_unknown), do: :invalid

  defp string(v) when is_binary(v), do: v
  defp string(_), do: nil
  defp integer(v) when is_integer(v), do: v
  defp integer(_), do: nil

  # Kick's event data as Kick sent it: a JSON string, decoded (or, the odd
  # time, already an object). What doesn't decode is kept as it came.
  defp data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, value} when value not in [nil, false] -> value
      _ -> data
    end
  end

  defp data(data), do: data

  # A message's text, and the data of events we don't parse, go further
  # only for a channel with chat logging on (§12.8); for the rest they end
  # here.
  defp forward(%{channel: %{chat_log: true}} = state, {:chat, message, text}),
    do: tap(state, &to_channel(&1, {:chat, message, text}))

  defp forward(state, {:chat, message, _text}), do: tap(state, &to_channel(&1, {:chat, message}))

  defp forward(%{channel: %{chat_log: true}} = state, {:other, name, feed, data}),
    do: tap(state, &to_channel(&1, {:pusher_other, name, feed, data, DateTime.utc_now()}))

  defp forward(state, {:other, name, feed, _data}),
    do: tap(state, &to_channel(&1, {:pusher_other, name, feed}))

  # The chat feed comes first in kicksdk's list.
  defp chat_feed(%{feeds: [feed | _]}), do: feed
  defp chat_feed(_state), do: nil

  defp listening?(%{session: nil}), do: false
  defp listening?(state), do: Session.subscribed?(state.session, chat_feed(state))

  defp to_channel(state, message) do
    if pid = ChannelServer.whereis(state.channel.kick_user_id), do: send(pid, message)
  end

  defp send_frame(%{ws: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.ws, frame) do
      {:ok, ws, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> %{state | ws: ws, conn: conn}
          {:error, conn, reason} -> reconnect(%{state | ws: ws, conn: conn}, reason)
        end

      {:error, ws, reason} ->
        reconnect(%{state | ws: ws}, reason)
    end
  end

  # When the session next needs the clock. A timer due sooner is kept: the
  # session's deadlines only move later with traffic, and a tick before
  # one is harmless.
  defp schedule_tick(%{session: nil} = state), do: state

  defp schedule_tick(state) do
    case Session.deadline(state.session) do
      at when is_integer(at) and (state.tick_at == nil or at < state.tick_at) ->
        Process.send_after(self(), :tick, max(at - now_ms(), 0))
        %{state | tick_at: at}

      _none_or_later ->
        state
    end
  end

  # Drop the connection and connect again at once, with the channel as it
  # is now; the gap is recorded under the channel as it was.
  defp again(state, old, reason) do
    state =
      if state.conn,
        do: %{reconnect(%{state | channel: old}, reason) | channel: state.channel},
        else: state

    %{state | backoff_ms: 1_000}
    |> cancel_timer()
    |> tap(fn _ -> send(self(), :connect) end)
  end

  # Drop the connection, record the gap, try again after the backoff.
  defp reconnect(%{conn: nil, timer: timer} = state, _reason) when timer != nil, do: state

  defp reconnect(state, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    if listening?(state), do: mark(state, false)

    retry_after_ms = retry_after_ms(reason)
    {delay_ms, state} = delay(state, retry_after_ms)

    if retry_after_ms > 0 do
      Logger.warning(
        "chat feed for channel #{state.channel.id}: Kick won't take this client back (#{inspect(reason)}), connecting as a new one in #{delay_ms}ms"
      )
    else
      Logger.info(
        "chat feed for channel #{state.channel.id} disconnected (#{inspect(reason)}), retrying in #{delay_ms}ms"
      )
    end

    %{
      state
      | conn: nil,
        ref: nil,
        ws: nil,
        upgrade: %{},
        client_id: nil,
        token: nil,
        session: nil,
        subscribed_at: nil,
        tick_at: nil
    }
    |> cancel_timer()
    |> schedule(:connect, delay_ms)
  end

  # The least kicksdk says to wait: more than 0 is a terminal close.
  defp retry_after_ms({:kick, %{"retry_after_ms" => ms}}) when is_integer(ms) and ms >= 0, do: ms

  defp retry_after_ms({:closed, code, _reason}) when is_integer(code) and code in 0..65_535,
    do: Realtime.retry_after_ms(code)

  defp retry_after_ms(_reason), do: 0

  # Only a connection that stayed up a while starts the ordinary backoff
  # over. A terminal close waits on kicksdk's backoff, whose streak only
  # the chat feed subscribing ends; the ordinary backoff is left as it was.
  defp delay(state, retry_after_ms) do
    backoff_ms = if stable?(state), do: 1_000, else: state.backoff_ms

    if retry_after_ms == 0 do
      {jitter(backoff_ms), %{state | backoff_ms: min(backoff_ms * 2, @max_backoff_ms)}}
    else
      {delay_ms, terminal} =
        Backoff.next_delay_for(state.terminal_backoff, retry_after_ms, :rand.uniform())

      {delay_ms, %{state | backoff_ms: backoff_ms, terminal_backoff: terminal}}
    end
  end

  defp stable?(%{subscribed_at: nil}), do: false

  defp stable?(state),
    do: System.monotonic_time(:millisecond) - state.subscribed_at >= @stable_ms

  @doc false
  # Between three quarters of the backoff and all of it.
  def jitter(ms), do: ms - :rand.uniform(div(ms, 4) + 1) + 1

  defp schedule(state, message, ms), do: %{state | timer: Process.send_after(self(), message, ms)}

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  # Listening: the `ChannelServer` journals it with the chat it vouches
  # for, so a mark never outlives counts that were lost (a crash, a
  # journal that can't be written). Not listening claims nothing and is
  # journaled at once.
  defp mark(state, true) do
    to_channel(
      state,
      {:chat_covered, KickTracker.Metrics.Sessionizer.norm(DateTime.utc_now()), @coverage_gap_s}
    )
  end

  defp mark(state, false) do
    Journal.append([
      {:coverage, [state.channel.id], "chat", false,
       KickTracker.Metrics.Sessionizer.norm(DateTime.utc_now()), @coverage_gap_s}
    ])
  rescue
    # Coverage is bookkeeping: trouble recording it must not drop the socket.
    error -> Logger.warning("could not record chat coverage: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("could not record chat coverage: #{inspect(reason)}")
  end

  # kicksdk's clock: any integer milliseconds, the same throughout.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
