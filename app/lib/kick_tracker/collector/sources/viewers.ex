defmodule KickTracker.Collector.Sources.Viewers do
  @moduledoc """
  Every 60s, `GET /livestreams` for every tracked channel, 50 per request
  (project.md §3): each channel's process gets its reading, the live
  stream's entry or `:offline` when a request that succeeded didn't list
  it. Polling every tracked channel, not only the live ones, makes a
  missed start event visible within a minute.

  A request that fails sends nothing: no reading is a gap, never
  "offline" and never zero (coverage source `api`). At the end of each
  cycle, one aggregated broadcast for the home page (§13.5) with every
  channel seen live and its viewers.
  """

  @behaviour KickTracker.Collector.Source

  alias KickTracker.Collector.Status
  alias KickTracker.Kick.API

  @batch 50

  @impl true
  def name, do: :viewers

  # A little over two polls: one late poll doesn't split a coverage period.
  @impl true
  def coverage, do: {"api", 150}

  @impl true
  def init(opts),
    do: %{interval_ms: Keyword.get(opts, :interval_ms, 60_000), viewers: %{}, live: %{}}

  @impl true
  def interval_ms(state), do: state.interval_ms

  @impl true
  def limits(_state), do: %{concurrency: 4, timeout_ms: 40_000}

  @impl true
  def units(channels, state, _now) do
    {Enum.map(Enum.chunk_every(channels, @batch), &%{channels: &1}), %{state | viewers: %{}}}
  end

  @impl true
  def fetch(%{channels: channels}),
    do: API.livestreams(Enum.map(channels, & &1.kick_user_id))

  @impl true
  def record(%{channels: channels}, {:ok, live}, at, state) do
    by_user = Map.new(live, &{&1["broadcaster_user_id"], &1})

    effects =
      for c <- channels,
          do: {:send, c.kick_user_id, {:reading, Map.get(by_user, c.kick_user_id, :offline), at}}

    viewers =
      for c <- channels,
          %{"viewer_count" => v} when is_integer(v) <- [by_user[c.kick_user_id]],
          into: state.viewers,
          do: {c.id, v}

    live_ids =
      Enum.reduce(channels, state.live, fn c, acc ->
        if Map.has_key?(by_user, c.kick_user_id),
          do: Map.put(acc, c.id, true),
          else: Map.delete(acc, c.id)
      end)

    {[], effects, %{state | viewers: viewers, live: live_ids}}
  end

  # Unknown, not offline: the channels keep whatever was known.
  def record(_unit, {:error, _}, _at, state), do: {[], [], state}

  @impl true
  def finish(state, at) do
    Status.put(:live_channels, state.live)

    {[],
     [
       {:broadcast, KickTracker.Tracking.live_topic(), {:live, %{at: at, viewers: state.viewers}}}
     ], state}
  end
end
