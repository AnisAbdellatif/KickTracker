defmodule KickTracker.Collector.Sources.Followers do
  @moduledoc """
  Follower totals from v2 (project.md §3): every 15 minutes while a
  channel is live, daily while offline, and on request — a stream's start
  and end (exact follower gain per stream, §3.1), a channel just added.
  One channel per request, one request at a time, a few per cycle, so v2
  never sees a burst (§14).

  A reading also stores the channel's chatroom id when it wasn't known,
  which chat needs. A failed reading is a gap (coverage source
  `followers`), never a zero. A channel whose readings keep failing (v2
  behind Cloudflare, a 404 after a rename) backs off: tried again 10
  minutes after the first failure, then 20, 40, ... up to 6 hours; one
  success resets it. The
  failures are kept in the journal, so a restart doesn't reset the
  backoff. Requests (a stream's start and end) are always served.
  """

  @behaviour KickTracker.Collector.Source

  require Logger

  alias KickTracker.Collector.{Journal, SourceRunner, Status}
  alias KickTracker.Kick.V2
  alias KickTracker.Repo

  @live_every_s 15 * 60
  @offline_every_s 24 * 3600
  @retry_after_s 10 * 60
  @max_retry_after_s 6 * 3600

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
      # channel id => {consecutive failures, last attempt}
      failures: nil,
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
    state = forget_failures(state, c.id)

    {ops, effects} =
      if chatroom_id && chatroom_id != c.chatroom_id,
        do:
          {ops ++ [{:channel_ids, c.id, nil, chatroom_id}],
           [{:channel, c.id, %{chatroom_id: chatroom_id}}]},
        else: {ops, []}

    {ops, effects, %{state | last: Map.put(state.last, c.id, at)}}
  end

  def record(%{channels: [c]}, {:error, _}, at, state) do
    {count, _} = Map.get(state.failures || %{}, c.id, {0, nil})
    failures = Map.put(state.failures || %{}, c.id, {count + 1, at})
    Journal.put(:follower_failures, failures)
    {[], [], %{state | failures: failures}}
  end

  @doc "How long after the last of `count` failures in a row a channel is tried again."
  @spec retry_after_s(pos_integer()) :: pos_integer()
  def retry_after_s(count),
    do: min(@retry_after_s * Integer.pow(2, min(count, 16) - 1), @max_retry_after_s)

  defp due?(c, state, live?, now) do
    every = if live?, do: @live_every_s, else: @offline_every_s
    last = state.last[c.id]

    (last == nil or DateTime.diff(now, last) >= every - 60) and
      case Map.get(state.failures || %{}, c.id) do
        nil -> true
        {count, at} -> DateTime.diff(now, at) >= retry_after_s(count)
      end
  end

  defp forget_failures(state, channel_id) do
    if Map.has_key?(state.failures || %{}, channel_id) do
      failures = Map.delete(state.failures, channel_id)
      Journal.put(:follower_failures, failures)
      %{state | failures: failures}
    else
      state
    end
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

    %{state | last: last, failures: state.failures || Journal.get(:follower_failures) || %{}}
  end

  defp load_last(state), do: state
end
