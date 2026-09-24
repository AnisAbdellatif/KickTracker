defmodule Sim.Recorder.Pusher do
  @moduledoc """
  Records raw frames from Kick's Pusher websocket, one JSON line per frame,
  in both directions, with the time each was seen.

  Runs in the calling process until the deadline. It answers Pusher's pings
  so the connection stays up, subscribes to the given channel names once the
  connection is established, and stops early if the socket closes (a
  recording that ended early says so in its last line).
  """

  alias Sim.Recorder.Store

  @type opts :: [run: Path.t(), name: String.t(), channels: [String.t()], deadline_ms: integer()]

  @spec record(String.t(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def record(url, opts) do
    uri = URI.parse(url)
    {http_scheme, ws_scheme} = if uri.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []),
         {:ok, conn, websocket, leftover} <- await_upgrade(conn, ref) do
      state = %{conn: conn, ref: ref, ws: websocket, frames: 0, opts: opts}

      state =
        log(state, "meta", %{"event" => "connected", "url" => url, "channels" => opts[:channels]})

      # The server's first frames can arrive in the same read as the upgrade.
      handle_responses(state, leftover)
    else
      {:error, _conn, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Returns the websocket plus any responses that arrived after the upgrade
  # completed, which already belong to the websocket.
  defp await_upgrade(conn, ref, acc \\ %{}) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      message when elem(message, 1) == socket ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {upgrade, rest} = Enum.split_while(responses, &(not match?({:done, ^ref}, &1)))

            acc =
              Enum.reduce(upgrade, acc, fn
                {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
                {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
                _, acc -> acc
              end)

            case rest do
              [{:done, ^ref} | leftover] ->
                with {:ok, conn, websocket} <-
                       Mint.WebSocket.new(conn, ref, acc.status, acc.headers) do
                  {:ok, conn, websocket, leftover}
                end

              [] ->
                await_upgrade(conn, ref, acc)
            end

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref, acc)
        end
    after
      15_000 -> {:error, :upgrade_timeout}
    end
  end

  defp loop(state) do
    remaining = state.opts[:deadline_ms] - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      state = log(state, "meta", %{"event" => "deadline"})
      Mint.HTTP.close(state.conn)
      {:ok, state.frames}
    else
      socket = Mint.HTTP.get_socket(state.conn)

      # Only this connection's messages; anything else sent to the calling
      # process is left in its mailbox.
      receive do
        message when elem(message, 1) == socket ->
          case Mint.WebSocket.stream(state.conn, message) do
            {:ok, conn, responses} ->
              handle_responses(%{state | conn: conn}, responses)

            {:error, conn, reason, _} ->
              stop(%{state | conn: conn}, {:stream_error, inspect(reason)})

            :unknown ->
              loop(state)
          end
      after
        min(remaining, 5_000) -> loop(state)
      end
    end
  end

  defp handle_responses(state, responses) do
    Enum.reduce_while(responses, {:cont, state}, fn
      {:data, ref, data}, {:cont, state} when ref == state.ref ->
        case Mint.WebSocket.decode(state.ws, data) do
          {:ok, ws, frames} ->
            {:cont, Enum.reduce(frames, {:cont, %{state | ws: ws}}, &handle_frame/2)}

          {:error, ws, reason} ->
            {:halt, {:stop, %{state | ws: ws}, {:decode_error, inspect(reason)}}}
        end

      _, acc ->
        {:cont, acc}
    end)
    |> case do
      {:cont, state} -> loop(state)
      {:stop, state, reason} -> stop(state, reason)
    end
  end

  defp handle_frame(_frame, {:stop, _, _} = stop), do: stop

  defp handle_frame({:text, text}, {:cont, state}) do
    state = log(state, "in", text)

    case Jason.decode(text) do
      {:ok, %{"event" => "pusher:connection_established"}} ->
        {:cont, Enum.reduce(state.opts[:channels], state, &subscribe/2)}

      {:ok, %{"event" => "pusher:ping"}} ->
        {:cont, send_text(state, ~s({"event":"pusher:pong","data":{}}))}

      _ ->
        {:cont, state}
    end
  end

  defp handle_frame({:ping, data}, {:cont, state}), do: {:cont, send_frame(state, {:pong, data})}

  defp handle_frame({:close, code, reason}, {:cont, state}),
    do: {:stop, state, {:closed, code, reason}}

  defp handle_frame(_other, acc), do: acc

  defp subscribe(channel, state) do
    send_text(
      state,
      Jason.encode!(%{
        "event" => "pusher:subscribe",
        "data" => %{"auth" => "", "channel" => channel}
      })
    )
  end

  defp send_text(state, text) do
    state |> log("out", text) |> send_frame({:text, text})
  end

  defp send_frame(state, frame) do
    {:ok, ws, data} = Mint.WebSocket.encode(state.ws, frame)

    case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} -> %{state | conn: conn, ws: ws}
      {:error, conn, _reason} -> %{state | conn: conn, ws: ws}
    end
  end

  defp stop(state, reason) do
    state = log(state, "meta", %{"event" => "stopped", "reason" => inspect(reason)})
    Mint.HTTP.close(state.conn)
    {:ok, state.frames}
  end

  defp log(state, direction, frame) do
    Store.append_line(state.opts[:run], "pusher", state.opts[:name], %{
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "direction" => direction,
      "frame" => frame
    })

    %{state | frames: state.frames + 1}
  end
end
