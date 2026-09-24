defmodule KickTracker.Collector.SourceRunner do
  @moduledoc """
  Runs one `Collector.Source` (project.md §10.3). Registered under the
  source's module name, so `GenServer.cast(Source, ...)` reaches it.

  Cycles keep a steady cadence however long the requests took; a cycle
  that overruns its interval is followed by the next one at once, never
  overlapped. Fetches run in tasks under `Collector.Tasks` with the
  source's concurrency and timeout, so one hung request can't hold the
  others. An exception in the source's own code fails that unit or cycle,
  logged, and the runner carries on: it doesn't crash on bad data.

  The channel list comes from `Collector.Tracked` (kept by the Manager),
  so a cycle needs no database; writes go to the journal.
  """

  use GenServer
  require Logger

  alias KickTracker.{Channels, Collector}
  alias KickTracker.Collector.{Journal, Status, Tracked}
  alias KickTracker.Metrics.Sessionizer

  @request_delay_ms 1_000

  @spec start_link(module() | {module(), keyword()}) :: GenServer.on_start()
  def start_link({source, opts}),
    do: GenServer.start_link(__MODULE__, {source, opts}, name: Keyword.get(opts, :name, source))

  def start_link(source), do: start_link({source, []})

  def child_spec(arg) do
    source = if is_tuple(arg), do: elem(arg, 0), else: arg
    %{id: {__MODULE__, source}, start: {__MODULE__, :start_link, [arg]}}
  end

  @doc "Runs a cycle now and returns when it is done. For tests."
  @spec run_now(GenServer.server(), timeout()) :: :ok
  def run_now(server, timeout \\ 60_000), do: GenServer.call(server, :run_now, timeout)

  @doc "Passes a request to a running source; a no-op if it isn't running here."
  @spec request(GenServer.server(), term()) :: :ok
  def request(server, message), do: GenServer.cast(server, {:request, message})

  @impl true
  def init({source, opts}) do
    state = %{
      source: source,
      sstate: source.init(opts),
      tasks: Keyword.get(opts, :tasks, Collector.Tasks),
      timer: nil
    }

    first_ms = Keyword.get_lazy(opts, :first_ms, fn -> resume_ms(source, state.sstate) end)
    {:ok, if(first_ms, do: schedule(state, first_ms), else: state)}
  end

  # A runner restarted (a crash, the collection tree restarting) keeps the
  # cadence of the one before: its first cycle comes when the next one was
  # due, not at once, so restarts in a row can't turn a 60s poll into a
  # burst of requests. When each cycle started is kept in the journal.
  defp resume_ms(source, sstate) do
    interval = source.interval_ms(sstate)

    case Journal.get({:source_cycle, source.name()}) do
      last when is_integer(last) ->
        (interval - (System.os_time(:millisecond) - last)) |> max(1_000) |> min(interval)

      _ ->
        1_000
    end
  end

  @impl true
  def handle_info(:cycle, state) do
    Journal.put({:source_cycle, state.source.name()}, System.os_time(:millisecond))
    started = System.monotonic_time(:millisecond)
    state = cycle(%{state | timer: nil})
    elapsed = System.monotonic_time(:millisecond) - started
    {:noreply, schedule(state, max(state.source.interval_ms(state.sstate) - elapsed, 0))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:run_now, _from, state), do: {:reply, :ok, cycle(state)}

  @impl true
  def handle_cast({:request, message}, state) do
    state = %{state | sstate: state.source.handle_request(message, state.sstate)}

    # Served soon, not at the next scheduled cycle.
    remaining = state.timer && Process.read_timer(state.timer)

    if remaining == nil or remaining == false or remaining > @request_delay_ms do
      {:noreply, state |> cancel() |> schedule(@request_delay_ms)}
    else
      {:noreply, state}
    end
  end

  # --- a cycle -------------------------------------------------------------------

  defp cycle(%{source: source} = state) do
    now = DateTime.utc_now()
    channels = Tracked.active()

    {units, sstate} =
      guard(source, :units, {[], state.sstate}, fn ->
        source.units(channels, state.sstate, now)
      end)

    limits = source.limits(sstate)

    outcomes =
      Task.Supervisor.async_stream_nolink(
        state.tasks,
        units,
        fn unit -> {fetch(source, unit), stamp()} end,
        max_concurrency: limits.concurrency,
        timeout: limits.timeout_ms,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(units)

    {ops, effects, sstate, failed} =
      Enum.reduce(outcomes, {[], [], sstate, 0}, &record_outcome(source, &1, &2))

    {end_ops, end_effects, sstate} =
      if function_exported?(source, :finish, 2),
        do: guard(source, :finish, {[], [], sstate}, fn -> source.finish(sstate, stamp()) end),
        else: {[], [], sstate}

    journal(source, ops ++ end_ops)
    Enum.each(effects ++ end_effects, &effect/1)

    Status.merge({:source, source.name()}, %{
      cycle_at: DateTime.utc_now(),
      units: length(units),
      failed: failed,
      ok_at:
        if(failed < length(units) or units == [],
          do: DateTime.utc_now(),
          else: (Status.get({:source, source.name()}) || %{})[:ok_at]
        )
    })

    %{state | sstate: sstate}
  end

  # One unit's outcome: what it writes, what it sets off, and whether it failed.
  defp record_outcome(source, {result, unit}, {ops, effects, s, failed}) do
    {outcome, at} =
      case result do
        {:ok, {outcome, at}} -> {outcome, at}
        {:exit, reason} -> {{:error, {:exit, reason}}, stamp()}
      end

    {recorded?, {more_ops, more_effects, s}} =
      case guard(source, :record, :failed, fn -> source.record(unit, outcome, at, s) end) do
        :failed -> {false, {[], [], s}}
        result -> {true, result}
      end

    ok? = match?({:ok, _}, outcome)
    if not ok?, do: Logger.warning("#{source.name()}: #{describe(outcome)}")

    # An answer whose meaning couldn't be recorded wrote nothing: a gap.
    coverage = if ok? and not recorded?, do: [], else: coverage(source, unit, outcome, at)

    {ops ++ more_ops ++ coverage, effects ++ more_effects, s,
     if(ok?, do: failed, else: failed + 1)}
  end

  defp fetch(source, unit) do
    case source.fetch(unit) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp coverage(source, unit, outcome, at) do
    case {source.coverage(), outcome} do
      {nil, _} ->
        []

      {{name, gap_s}, {:ok, _}} ->
        case covered(source, unit, outcome) do
          [] -> []
          ids -> [{:coverage, ids, name, true, at, gap_s}]
        end

      {{name, gap_s}, _failed} ->
        [{:coverage, Enum.map(unit.channels, & &1.id), name, false, at, gap_s}]
    end
  end

  defp covered(source, unit, outcome) do
    if function_exported?(source, :covered, 2),
      do: guard(source, :covered, [], fn -> source.covered(unit, outcome) end),
      else: Enum.map(unit.channels, & &1.id)
  end

  defp journal(source, ops) do
    Journal.append(ops)
  rescue
    error -> Logger.error("#{source.name()}: could not journal: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.error("#{source.name()}: could not journal: #{inspect(reason)}")
  end

  defp effect({:send, kick_user_id, message}) do
    if pid = Collector.channel_pid(kick_user_id), do: send(pid, message)
  end

  defp effect({:broadcast, topic, message}),
    do: Phoenix.PubSub.broadcast(KickTracker.PubSub, topic, message)

  defp effect({:channel, channel_id, fields}) do
    Tracked.update(channel_id, fields)
    Channels.announce(channel_id, fields)
  end

  # The source's own code must not take the runner down.
  defp guard(source, what, fallback, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "#{source.name()}: #{what} failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      fallback
  end

  defp describe({:error, %{__exception__: true} = e}), do: Exception.message(e)
  defp describe({:error, reason}), do: inspect(reason, limit: 10)

  defp stamp, do: Sessionizer.norm(DateTime.utc_now())

  defp schedule(state, ms), do: %{state | timer: Process.send_after(self(), :cycle, ms)}

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
