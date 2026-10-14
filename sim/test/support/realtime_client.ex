defmodule Sim.RealtimeClient do
  @moduledoc """
  A client of the fake realtime server for tests, connecting the way the
  app does: where to connect and a guest token over HTTP, then the
  websocket, with kicksdk's `Kicksdk.Realtime.Session` speaking the
  protocol. A mismatch between the fake and what kicksdk expects of the
  real Kick shows up here rather than in the app.

  Runs in the calling process until `ms` have passed or the socket closes,
  and returns what happened: kicksdk's actions in order, the text frames
  in each direction, and how the socket closed.
  """

  alias Kicksdk.Realtime
  alias Kicksdk.Realtime.Session

  @type result :: %{
          actions: [map()],
          in: [String.t()],
          out: [String.t()],
          closed: {:refused, pos_integer()} | {integer(), String.t()} | String.t() | nil
        }

  @doc """
  Options: `:base` (the realtime endpoints, default the running fake's),
  `:origin` (default kick.com's), `:refresh` (answer `refresh_token`,
  default true).
  """
  @spec run([String.t()], non_neg_integer(), keyword()) :: result()
  def run(feeds, ms, opts \\ []) do
    endpoints = %{realtime: Keyword.get_lazy(opts, :base, &Sim.Instance.realtime_url/0)}
    client_id = "test-client"

    {:ok, [%{"url" => url} | _]} =
      http(Realtime.connection_request(client_id, endpoints), &Realtime.parse_connection/2)

    uri = URI.parse(url)
    origin = Keyword.get(opts, :origin, Realtime.required_origin())

    {:ok, conn} = Mint.HTTP.connect(:http, uri.host, uri.port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, uri.path, [{"origin", origin}])
    deadline = now() + ms

    state = %{
      conn: conn,
      ref: ref,
      ws: nil,
      upgrade: %{},
      session: Session.new(feeds),
      token: fn -> http(Realtime.token_request(client_id, endpoints), &Realtime.parse_token/2) end,
      refresh?: Keyword.get(opts, :refresh, true),
      result: %{actions: [], in: [], out: [], closed: nil}
    }

    state
    |> loop(deadline)
    |> then(fn state ->
      Mint.HTTP.close(state.conn)
      r = state.result
      %{r | actions: Enum.reverse(r.actions), in: Enum.reverse(r.in), out: Enum.reverse(r.out)}
    end)
  end

  @doc "The events among a run's actions: `{feed, Kick's event name, typed event}`."
  def events(%{actions: actions}),
    do: for(%{"action" => "event"} = a <- actions, do: {a["channel"], a["name"], a["event"]})

  defp loop(%{result: %{closed: closed}} = state, _deadline) when closed != nil, do: state

  defp loop(state, deadline) do
    wait = min(deadline, Session.deadline(state.session) || deadline) - now()

    receive do
      message ->
        case Mint.WebSocket.stream(state.conn, message) do
          {:ok, conn, responses} -> state |> Map.put(:conn, conn) |> responses(responses)
          {:error, conn, reason, _} -> close(%{state | conn: conn}, inspect(reason))
          :unknown -> state
        end
        |> loop(deadline)
    after
      max(wait, 0) ->
        if now() >= deadline,
          do: state,
          else: state |> act(Session.tick(state.session, now())) |> loop(deadline)
    end
  end

  # The upgrade's answer first; frames can follow in the same read.
  defp responses(%{ws: nil, ref: ref} = state, responses) do
    {upgrade, rest} = Enum.split_while(responses, &(not match?({:done, ^ref}, &1)))

    acc =
      Enum.reduce(upgrade, state.upgrade, fn
        {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
        {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
        _, acc -> acc
      end)

    case {rest, acc[:status]} do
      {[], _} ->
        %{state | upgrade: acc}

      {[{:done, ^ref} | leftover], 101} ->
        {:ok, conn, ws} = Mint.WebSocket.new(state.conn, ref, 101, acc[:headers])
        state = %{state | conn: conn, ws: ws}
        {:ok, token} = state.token.()
        state |> act(Session.open(state.session, token, now())) |> responses(leftover)

      {_, status} ->
        put_in(state.result.closed, {:refused, status})
    end
  end

  defp responses(state, responses) do
    Enum.reduce(responses, state, fn
      {:data, _ref, data}, %{ws: ws} = state ->
        {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)
        Enum.reduce(frames, %{state | ws: ws}, &frame/2)

      _, state ->
        state
    end)
  end

  defp frame(_frame, %{result: %{closed: closed}} = state) when closed != nil, do: state

  defp frame({:text, text}, state) do
    state = update_in(state.result.in, &[text | &1])
    act(state, Session.receive(state.session, text, now()))
  end

  defp frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp frame({:close, code, reason}, state), do: put_in(state.result.closed, {code, reason})
  defp frame(_other, state), do: state

  defp act(state, actions) do
    Enum.reduce(actions, state, fn action, state ->
      state = update_in(state.result.actions, &[action | &1])

      case action do
        %{"action" => "send", "text" => text} ->
          state = update_in(state.result.out, &[text | &1])
          send_frame(state, {:text, text})

        %{"action" => "close", "reason" => reason} ->
          close(state, reason)

        %{"action" => "refresh_token"} when state.refresh? ->
          {:ok, token} = state.token.()
          act(state, Session.refresh(state.session, token, now()))

        _ ->
          state
      end
    end)
  end

  defp close(state, reason) do
    Session.closed(state.session)
    put_in(state.result.closed, state.result.closed || reason)
  end

  defp send_frame(state, frame) do
    {:ok, ws, data} = Mint.WebSocket.encode(state.ws, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
    %{state | ws: ws, conn: conn}
  end

  defp http(%{"method" => "POST", "url" => url, "headers" => headers, "body" => body}, parse) do
    %{status: status, body: body} =
      Req.post!(url, headers: headers, body: body, decode_body: false, retry: false)

    parse.(status, body)
  end

  # kicksdk's clock: any integer milliseconds, the same throughout.
  defp now, do: System.monotonic_time(:millisecond)
end
