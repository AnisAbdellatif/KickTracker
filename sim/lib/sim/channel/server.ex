defmodule Sim.Channel.Server do
  @moduledoc """
  One simulated channel, ticking: it watches simulated time and delivers
  whatever `Sim.Channel.Timeline` says the channel owes.

  The process holds no simulated state of its own beyond where it has got
  to. Everything it announces comes from pure functions of time, so a
  crash and restart costs at most the events of the moment it missed, and
  never changes what the channel looks like.
  """

  use GenServer, restart: :transient

  alias Sim.Channel.Timeline
  alias Sim.{Server, Webhooks}

  @default_tick_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    channel = Keyword.fetch!(opts, :channel)
    GenServer.start_link(__MODULE__, opts, name: via(channel.slug))
  end

  @doc "The process for this channel's slug, if it is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(slug) do
    case Registry.lookup(Sim.Channel.Registry, String.downcase(slug)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Runs a tick now instead of waiting for the timer. Returns what it delivered."
  @spec tick(String.t()) :: [String.t()]
  def tick(slug), do: GenServer.call(via(slug), :tick)

  @doc "What this channel has delivered so far, newest first."
  @spec delivered(String.t()) :: [{String.t(), DateTime.t()}]
  def delivered(slug), do: GenServer.call(via(slug), :delivered)

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    now = Server.now()

    state = %{
      channel: channel,
      timeline: Timeline.start(channel, now),
      tick_ms: tick_ms,
      delivered: []
    }

    if tick_ms > 0, do: Process.send_after(self(), :tick, tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {state, _emitted} = step(state)
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick, _from, state) do
    {state, emitted} = step(state)
    {:reply, emitted, state}
  end

  def handle_call(:delivered, _from, state), do: {:reply, state.delivered, state}

  # Returns the new state and the events delivered, in the order they were
  # sent: Kick's order matters (status before metadata), so callers see it.
  defp step(state) do
    now = Server.now()
    {emissions, timeline} = Timeline.advance(state.channel, state.timeline, now)

    for {event, body} <- emissions do
      Webhooks.deliver(state.channel.user_id, event, body, now)
    end

    emitted = Enum.map(emissions, &elem(&1, 0))
    delivered = Enum.reduce(emitted, state.delivered, &[{&1, now} | &2])

    {%{state | timeline: timeline, delivered: Enum.take(delivered, 500)}, emitted}
  end

  defp via(slug), do: {:via, Registry, {Sim.Channel.Registry, String.downcase(slug)}}
end
