defmodule KickTracker.Collector.Sources.Followers do
  @moduledoc """
  Follower totals from v2 (project.md §3): every 15 minutes while a
  channel is live, daily while offline, and on request — a stream's start
  and end (exact follower gain per stream, §3.1), a channel just added.
  One channel per request, one request at a time, a few per cycle, so v2
  never sees a burst (§14).

  A reading also stores the channel's chatroom id when it wasn't known,
  which chat needs. A failed reading is a gap (coverage source
  `followers`), never a zero, and the channel is tried again 10 minutes
  later, not at every cycle.
  """

  @behaviour KickTracker.Collector.Source

  require Logger

  alias KickTracker.Collector.{SourceRunner, Status}
  alias KickTracker.Kick.V2
  alias KickTracker.Repo

  @live_every_s 15 * 60
  @offline_every_s 24 * 3600
  @retry_after_s 10 * 60

  @doc "Asks for a reading of a channel soon. A no-op where collection doesn't run."
  @spec request(integer(), atom() | String.t()) :: :ok
  def request(channel_id, reason), do: SourceRunner.request(__MODULE__, {channel_id, reason})

  @impl true
  def name, do: :followers

  @impl true
  def coverage, do: {"followers", 1_000}

  @impl true
  def init(opts) do
    %{
      interval_ms: Keyword.get(opts, :interval_ms, 15_000),
      per_cycle: Keyword.get(opts, :per_cycle, 3),
      last: nil,
      attempted: %{},
      requests: []
    }
  end

  @impl true
  def interval_ms(state), do: state.interval_ms

  @impl true
  def limits(_state), do: %{concurrency: 1, timeout_ms: 20_000}

  @impl true
  def handle_request({channel_id, _reason}, state),
    do: %{state | requests: Enum.uniq(state.requests ++ [channel_id])}

  @impl true
  def units(channels, state, now) do
    state = load_last(state)
    live = Status.get(:live_channels) || %{}
    by_id = Map.new(channels, &{&1.id, &1})

    requested = for id <- state.requests, c = by_id[id], c != nil, do: c

    due =
      channels
      |> Enum.reject(&(&1.id in state.requests))
      |> Enum.filter(&due?(&1, state, Map.has_key?(live, &1.id), now))
      |> Enum.sort_by(&(state.last[&1.id] || ~U[1970-01-01 00:00:00Z]), DateTime)
      |> Enum.take(max(state.per_cycle - length(requested), 0))

    # Requests for channels not tracked (yet) wait for the next cycle.
    waiting = Enum.reject(state.requests, &Map.has_key?(by_id, &1))
    {Enum.map(requested ++ due, &%{channels: [&1]}), %{state | requests: waiting}}
  end

  @impl true
  def fetch(%{channels: [c]}), do: V2.channel(c.slug)

  @impl true
  def record(
        %{channels: [c]},
        {:ok, %{followers: followers, chatroom_id: chatroom_id}},
        at,
        state
      ) do
    ops = [{:follower_sample, c.id, at, followers}]

    {ops, effects} =
      if chatroom_id && chatroom_id != c.chatroom_id,
        do:
          {ops ++ [{:channel_ids, c.id, nil, chatroom_id}],
           [{:channel, %{c | chatroom_id: chatroom_id}}]},
        else: {ops, []}

    {ops, effects, %{state | last: Map.put(state.last, c.id, at)}}
  end

  def record(%{channels: [c]}, {:error, _}, at, state),
    do: {[], [], %{state | attempted: Map.put(state.attempted, c.id, at)}}

  defp due?(c, state, live?, now) do
    every = if live?, do: @live_every_s, else: @offline_every_s
    last = state.last[c.id]
    attempted = state.attempted[c.id]

    (last == nil or DateTime.diff(now, last) >= every - 60) and
      (attempted == nil or DateTime.diff(now, attempted) >= @retry_after_s)
  end

  # When each channel was last read, from the database once; if it can't
  # be read, every channel counts as due and the per-cycle limit spreads
  # them out.
  defp load_last(%{last: nil} = state) do
    last =
      try do
        Repo.query!(
          "SELECT channel_id, max(observed_at) FROM follower_samples GROUP BY channel_id",
          [],
          timeout: 10_000
        ).rows
        |> Map.new(&List.to_tuple/1)
      rescue
        error ->
          Logger.warning("followers: last readings unknown (#{Exception.message(error)})")
          %{}
      end

    %{state | last: last}
  end

  defp load_last(state), do: state
end
