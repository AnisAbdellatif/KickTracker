defmodule Receiver.Publisher do
  @moduledoc """
  Publishes envelopes to RabbitMQ and waits for the broker's confirm, so
  `:ok` means RabbitMQ has taken responsibility for the message.

  Anything else is an error the caller turns into a spool write: not
  connected, the broker blocking publishers (a memory or disk alarm), a
  negative confirm, no confirm in time, or the message being **returned**
  as unroutable (published `mandatory`, so a missing binding can't make
  messages vanish while the broker still confirms them).

  Waiting is bounded everywhere: the confirm wait is `confirm_timeout_ms`,
  and `publish/5` gives up a second after that (the caller spools), so a
  broker that stops confirming can't hold a delivery for longer. A request
  that has already been given up on by its caller is not published at all.

  It reconnects on its own, through **one** path: the first `:DOWN` of the
  current connection or channel tears both down (monitors dropped, the old
  connection closed) and schedules a single reconnect, with exponential
  backoff and jitter; `:DOWN`s of anything older are ignored. While
  disconnected, `publish/5` answers `{:error, :not_connected}` at once.

  Whether it is connected is kept in `:persistent_term` (written only when
  it changes), so `connected?/1` and `status/1` never wait behind a
  publish: the load balancer's health check must answer within 2s whatever
  RabbitMQ is doing.
  """

  use GenServer
  require Logger

  @min_backoff_ms 500
  @max_backoff_ms 30_000
  # How long after a lost connection the first reconnect is tried.
  @reconnect_ms 250
  # What `publish/5` waits beyond the confirm timeout before giving up.
  @call_margin_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Publishes one message and waits for RabbitMQ's confirm, for at most the
  confirm timeout plus a second (`:timeout` in `call_opts` overrides).
  """
  @spec publish(String.t(), binary(), keyword(), GenServer.server(), keyword()) ::
          :ok | {:error, term()}
  def publish(routing_key, payload, options, server \\ __MODULE__, call_opts \\ []) do
    timeout = Keyword.get_lazy(call_opts, :timeout, fn -> call_timeout(server) end)
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(server, {:publish, routing_key, payload, options, deadline}, timeout)
  catch
    :exit, reason -> {:error, {:publisher_unavailable, reason}}
  end

  @doc "Whether RabbitMQ is taking publishes right now (connected and not blocked). Never blocks."
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__), do: status(server).connected

  @doc """
  The publisher's state, read without calling it: whether it is connected
  (and not blocked), and for how long it hasn't been (`nil` while it is).
  """
  @spec status(GenServer.server()) :: %{
          connected: boolean(),
          disconnected_for_ms: non_neg_integer() | nil
        }
  def status(server \\ __MODULE__) do
    case :persistent_term.get(key(server), nil) do
      %{pid: pid, connected: connected, since: since} ->
        cond do
          not Process.alive?(pid) -> %{connected: false, disconnected_for_ms: nil}
          connected -> %{connected: true, disconnected_for_ms: nil}
          true -> %{connected: false, disconnected_for_ms: now() - since}
        end

      nil ->
        %{connected: false, disconnected_for_ms: nil}
    end
  end

  @impl true
  def init(opts) do
    # So a shutdown closes the connection: it isn't linked to us and would
    # otherwise outlive the publisher.
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    confirm_timeout_ms = Keyword.get(opts, :confirm_timeout_ms, 5_000)

    state = %{
      name: name,
      url: Keyword.fetch!(opts, :url),
      exchange: Keyword.fetch!(opts, :exchange),
      confirm_timeout_ms: confirm_timeout_ms,
      # The broker's wait, injectable so tests can stand in for a broker
      # that never confirms.
      confirm: Keyword.get(opts, :confirm, &wait_for_confirms/2),
      connection_name: Keyword.get(opts, :connection_name, default_connection_name()),
      conn: nil,
      chan: nil,
      refs: [],
      blocked: false,
      backoff_ms: @min_backoff_ms,
      timer: nil
    }

    :persistent_term.put(
      {__MODULE__, :call_timeout, name},
      confirm_timeout_ms + @call_margin_ms
    )

    put_status(state, false)
    {:ok, schedule_connect(state, 0)}
  end

  @impl true
  def handle_call({:publish, routing_key, payload, options, deadline}, _from, state) do
    cond do
      # The caller has given up and spooled it; publishing now would only
      # make a duplicate and hold up the next delivery.
      now() >= deadline -> {:reply, {:error, :expired}, state}
      state.chan == nil -> {:reply, {:error, :not_connected}, state}
      state.blocked -> {:reply, {:error, :blocked}, state}
      true -> do_publish(state, routing_key, payload, options, deadline)
    end
  end

  @impl true
  def handle_info({:connect, timer}, %{timer: timer} = state) do
    state = %{state | timer: nil}
    if state.chan != nil, do: {:noreply, state}, else: {:noreply, connect(state)}
  end

  # A reconnect from before the last teardown: already superseded.
  def handle_info({:connect, _stale}, state), do: {:noreply, state}

  # The current connection or channel went away: drop both, reconnect once.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if ref in state.refs do
      Logger.warning("RabbitMQ connection lost (#{inspect(reason)})")
      state = teardown(state)
      {:noreply, schedule_connect(state, jitter(@reconnect_ms))}
    else
      {:noreply, state}
    end
  end

  # A memory or disk alarm on the broker: it stops reading what we publish.
  # Spool meanwhile instead of waiting on it.
  def handle_info({:"connection.blocked", reason}, state) do
    Logger.warning("RabbitMQ is blocking publishers (#{inspect(reason)})")
    state = %{state | blocked: true}
    put_status(state, false)
    {:noreply, state}
  end

  def handle_info({:"connection.unblocked"}, state) do
    Logger.info("RabbitMQ accepts publishes again")
    state = %{state | blocked: false}
    put_status(state, state.chan != nil)
    {:noreply, state}
  end

  # A return that arrives outside a publish (a late one); ignore.
  def handle_info({{:"basic.return", _, _, _, _}, _message}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state.conn)
    :persistent_term.erase(key(state.name))
    :persistent_term.erase({__MODULE__, :call_timeout, state.name})
  end

  defp connect(state) do
    case open(state) do
      {:ok, conn, chan} ->
        refs = [Process.monitor(conn.pid), Process.monitor(chan.pid)]
        Logger.info("connected to RabbitMQ")
        state = %{state | conn: conn, chan: chan, refs: refs, blocked: false}
        # Registered after the monitors: if the broker is already in alarm,
        # the blocked message arrives at once and is handled next.
        :amqp_connection.register_blocked_handler(conn.pid, self())
        put_status(state, true)
        %{state | backoff_ms: @min_backoff_ms}

      {:error, error} ->
        delay = jitter(state.backoff_ms)
        Logger.warning("RabbitMQ unreachable (#{inspect(error)}), retrying in #{delay}ms")
        state = %{state | backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}
        schedule_connect(state, delay)
    end
  end

  # Opens a connection and a confirming channel, or nothing: a connection
  # whose channel failed is closed, not left behind.
  defp open(state) do
    case AMQP.Connection.open(state.url, name: state.connection_name) do
      {:ok, conn} ->
        with {:ok, chan} <- AMQP.Channel.open(conn),
             :ok <- AMQP.Confirm.select(chan),
             # Registered with the Erlang client directly, not through
             # `AMQP.Basic.return/2`: that relays returns through another
             # process, so they arrive after the confirm and look like
             # success. Directly, a return is always in the mailbox before
             # its confirm.
             :ok <- :amqp_channel.register_return_handler(chan.pid, self()) do
          {:ok, conn, chan}
        else
          error ->
            close(conn)
            {:error, error}
        end

      error ->
        {:error, error}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp teardown(state) do
    Enum.each(state.refs, &Process.demonitor(&1, [:flush]))
    close(state.conn)
    state = %{state | conn: nil, chan: nil, refs: [], blocked: false}
    put_status(state, false)
    state
  end

  # One reconnect at a time: a pending one stays as it is.
  defp schedule_connect(%{timer: nil} = state, delay) do
    token = make_ref()
    Process.send_after(self(), {:connect, token}, delay)
    %{state | timer: token}
  end

  defp schedule_connect(state, _delay), do: state

  defp do_publish(state, routing_key, payload, options, deadline) do
    options = Keyword.put(options, :mandatory, true)
    discard_stale_returns()

    reply =
      with :ok <- AMQP.Basic.publish(state.chan, state.exchange, routing_key, payload, options) do
        confirmed(state, deadline)
      end

    {:reply, reply, state}
  rescue
    error -> {:reply, {:error, {:publish_failed, Exception.message(error)}}, state}
  catch
    # The broker closed the channel mid-publish (a permission error, say):
    # report it; the channel's exit brings a reconnect.
    :exit, reason -> {:reply, {:error, {:channel_closed, reason}}, state}
    # amqp_channel throws what the channel answered instead of a verdict.
    :throw, reason -> {:reply, {:error, {:confirm_failed, reason}}, state}
  end

  # Waits for the broker's verdict, never past the caller's deadline. An
  # unroutable mandatory message is returned before it is acked, and
  # publishes go one at a time, so a return in the mailbox once the confirm
  # is in means this message went nowhere, whatever the confirm says.
  defp confirmed(state, deadline) do
    wait_ms = max(min(state.confirm_timeout_ms, deadline - now()), 0)

    case state.confirm.(state.chan, wait_ms) do
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

  # `amqp_channel:wait_for_confirms/2` reads a bare integer as **seconds**;
  # the tuple form is milliseconds.
  defp wait_for_confirms(chan, timeout_ms),
    do: AMQP.Confirm.wait_for_confirms(chan, {timeout_ms, :millisecond})

  defp discard_stale_returns do
    receive do
      {{:"basic.return", _, _, _, _}, _} -> discard_stale_returns()
    after
      0 -> :ok
    end
  end

  defp close(nil), do: :ok

  defp close(conn) do
    AMQP.Connection.close(conn)
  catch
    _, _ -> :ok
  end

  defp put_status(state, connected) do
    connected = connected and not state.blocked
    key = key(state.name)

    case :persistent_term.get(key, nil) do
      %{pid: pid, connected: ^connected} when pid == self() ->
        :ok

      _ ->
        :persistent_term.put(key, %{pid: self(), connected: connected, since: now()})
    end
  end

  defp call_timeout(server),
    do: :persistent_term.get({__MODULE__, :call_timeout, server}, 5_000 + @call_margin_ms)

  defp key(server), do: {__MODULE__, :status, server}

  defp default_connection_name do
    receiver = Application.get_env(:receiver, :receiver_id, "receiver")
    "receiver #{receiver}"
  end

  # Somewhere between half and all of `ms`, so receivers that lost the
  # broker together don't come back in lockstep.
  defp jitter(ms), do: div(ms, 2) + :rand.uniform(div(ms, 2) + 1) - 1

  defp now, do: System.monotonic_time(:millisecond)
end
