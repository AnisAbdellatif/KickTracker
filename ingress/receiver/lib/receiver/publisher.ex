defmodule Receiver.Publisher do
  @moduledoc """
  Publishes envelopes to RabbitMQ and waits for the broker's confirm, so
  `:ok` means RabbitMQ has taken responsibility for the message.

  Anything else is an error the caller turns into a spool write: not
  connected, a negative confirm, no confirm in time, or the message being
  **returned** as unroutable (published `mandatory`, so a missing binding
  can't make messages vanish while the broker still confirms them).

  It reconnects on its own, with backoff, and never blocks a delivery
  waiting for the broker to come back: while disconnected, `publish/4`
  answers `{:error, :not_connected}` at once.
  """

  use GenServer
  require Logger

  @max_backoff_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Publishes one message and waits for RabbitMQ's confirm."
  @spec publish(String.t(), binary(), keyword(), GenServer.server()) :: :ok | {:error, term()}
  def publish(routing_key, payload, options, server \\ __MODULE__) do
    GenServer.call(server, {:publish, routing_key, payload, options}, :infinity)
  catch
    :exit, reason -> {:error, {:publisher_unavailable, reason}}
  end

  @doc "Whether a channel to RabbitMQ is open right now."
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__) do
    GenServer.call(server, :connected?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :url),
      exchange: Keyword.fetch!(opts, :exchange),
      confirm_timeout_ms: Keyword.get(opts, :confirm_timeout_ms, 5_000),
      conn: nil,
      chan: nil,
      backoff_ms: 500
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.chan != nil, state}

  def handle_call({:publish, _key, _payload, _opts}, _from, %{chan: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, routing_key, payload, options}, _from, state) do
    options = Keyword.put(options, :mandatory, true)
    discard_stale_returns()

    reply =
      with :ok <- AMQP.Basic.publish(state.chan, state.exchange, routing_key, payload, options) do
        confirmed(state)
      end

    {:reply, reply, state}
  rescue
    error -> {:reply, {:error, {:publish_failed, Exception.message(error)}}, state}
  catch
    # The broker closed the channel mid-publish (a permission error, say):
    # report it; the channel's exit brings a reconnect.
    :exit, reason -> {:reply, {:error, {:channel_closed, reason}}, state}
  end

  @impl true
  def handle_info(:connect, state) do
    with {:ok, conn} <- AMQP.Connection.open(state.url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Confirm.select(chan),
         # Registered with the Erlang client directly, not through
         # `AMQP.Basic.return/2`: that relays returns through another
         # process, so they arrive after the confirm and look like success.
         # Directly, a return is always in the mailbox before its confirm.
         :ok <- :amqp_channel.register_return_handler(chan.pid, self()) do
      Process.monitor(conn.pid)
      Process.monitor(chan.pid)
      Logger.info("connected to RabbitMQ")
      {:noreply, %{state | conn: conn, chan: chan, backoff_ms: 500}}
    else
      error ->
        Logger.warning(
          "RabbitMQ unreachable (#{inspect(error)}), retrying in #{state.backoff_ms}ms"
        )

        Process.send_after(self(), :connect, state.backoff_ms)
        {:noreply, %{state | backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}}
    end
  end

  # The connection or channel went away: drop both and reconnect.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("RabbitMQ connection lost (#{inspect(reason)})")
    close(state)
    send(self(), :connect)
    {:noreply, %{state | conn: nil, chan: nil}}
  end

  # A return that arrives outside a publish (shouldn't happen); ignore.
  def handle_info({{:"basic.return", _, _, _, _}, _message}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close(state)

  # Waits for the broker's verdict. An unroutable mandatory message is
  # returned before it is acked, and publishes go one at a time, so a
  # return in the mailbox once the confirm is in means this message went
  # nowhere, whatever the confirm says.
  defp confirmed(state) do
    case AMQP.Confirm.wait_for_confirms(state.chan, state.confirm_timeout_ms) do
      true ->
        receive do
          {{:"basic.return", _code, _text, _exchange, _key}, _message} -> {:error, :unroutable}
        after
          0 -> :ok
        end

      false ->
        {:error, :nacked}

      :timeout ->
        {:error, :confirm_timeout}
    end
  end

  defp discard_stale_returns do
    receive do
      {{:"basic.return", _, _, _, _}, _} -> discard_stale_returns()
    after
      0 -> :ok
    end
  end

  defp close(%{conn: nil}), do: :ok

  defp close(%{conn: conn}) do
    AMQP.Connection.close(conn)
  catch
    _, _ -> :ok
  end
end
