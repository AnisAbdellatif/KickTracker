defmodule KickTracker.Tracking.Poller do
  @moduledoc """
  Batched polling of Kick's public API (project.md §3, §10).

    * Every **60s**: `GET /livestreams` for every tracked channel, 50 per
      request. Each channel's process gets its reading: the channel's
      entry, or `:offline` when a request that succeeded didn't list it.
    * Every **5 minutes**: `GET /channels`, for subscriber totals and slug
      renames.

  Polling every tracked channel, not only the live ones, makes a missed
  start event visible within a minute, at one request per 50 channels.

  A request that fails sends nothing: no reading is a gap, never
  "offline" and never zero. Each batch's outcome is recorded in
  `coverage` (source `api`).
  """

  use GenServer
  require Logger

  alias KickTracker.{Channels, Stats}
  alias KickTracker.Kick.API
  alias KickTracker.Stats.Coverage
  alias KickTracker.Tracking.ChannelServer

  @batch 50
  # A little over two polls: one late poll doesn't split a coverage period.
  @coverage_gap_s 150
  @channels_gap_s 660

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Polls now (livestreams, and channels too if `channels: true`). For tests."
  @spec poll_now(keyword(), GenServer.server()) :: :ok
  def poll_now(opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:poll_now, opts}, 60_000)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      channels_every: Keyword.get(opts, :channels_every, 5),
      tick: 0
    }

    if state.interval_ms > 0, do: Process.send_after(self(), :tick, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_call({:poll_now, opts}, _from, state) do
    channels = Channels.list_active()
    poll_livestreams(channels)
    if opts[:channels], do: poll_channels(channels)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    started = System.monotonic_time(:millisecond)
    channels = Channels.list_active()

    poll_livestreams(channels)
    if rem(state.tick, state.channels_every) == 0, do: poll_channels(channels)

    # Keep a steady cadence however long the polls took.
    elapsed = System.monotonic_time(:millisecond) - started
    Process.send_after(self(), :tick, max(state.interval_ms - elapsed, 1_000))
    {:noreply, %{state | tick: state.tick + 1}}
  end

  defp poll_livestreams(channels) do
    for batch <- Enum.chunk_every(channels, @batch) do
      ids = Enum.map(batch, & &1.kick_user_id)
      result = API.livestreams(ids)
      at = now()

      case result do
        {:ok, live} when is_list(live) ->
          by_user = Map.new(live, &{&1["broadcaster_user_id"], &1})

          for channel <- batch, pid = ChannelServer.whereis(channel.kick_user_id) do
            send(pid, {:reading, Map.get(by_user, channel.kick_user_id, :offline), at})
          end

          Coverage.mark(Enum.map(batch, & &1.id), "api", true, at, @coverage_gap_s)

        other ->
          Logger.warning("livestreams poll failed: #{inspect(other)}")
          Coverage.mark(Enum.map(batch, & &1.id), "api", false, at, @coverage_gap_s)
      end
    end

    :ok
  end

  defp poll_channels(channels) do
    for batch <- Enum.chunk_every(channels, @batch) do
      case API.channels(Enum.map(batch, & &1.kick_user_id)) do
        {:ok, found} when is_list(found) ->
          at = now()
          by_user = Map.new(found, &{&1["broadcaster_user_id"], &1})

          samples =
            for channel <- batch, data = by_user[channel.kick_user_id], data != nil do
              observe_slug(channel, data, at)
              subscriber_sample(channel, data, at)
            end

          samples |> Enum.reject(&is_nil/1) |> Stats.insert_subscriber_samples()
          Coverage.mark(Enum.map(batch, & &1.id), "subscribers", true, at, @channels_gap_s)

        other ->
          Logger.warning("channels poll failed: #{inspect(other)}")
          Coverage.mark(Enum.map(batch, & &1.id), "subscribers", false, now(), @channels_gap_s)
      end
    end

    :ok
  end

  defp observe_slug(channel, %{"slug" => slug}, at) when is_binary(slug) and slug != "" do
    updated = Channels.observe_slug(channel, slug, at)
    if updated.slug != channel.slug, do: Channels.announce(updated)
  end

  defp observe_slug(_channel, _data, _at), do: :ok

  defp subscriber_sample(channel, data, at) do
    counts =
      {data["active_subscribers_count"], data["active_gifted_subscribers_count"],
       data["canceled_subscribers_count"]}

    case counts do
      {a, g, c} when is_integer(a) and is_integer(g) and is_integer(c) ->
        %{channel_id: channel.id, observed_at: at, active: a, active_gifted: g, canceled: c}

      # A field missing is no reading, never a zero.
      _ ->
        nil
    end
  end

  defp now, do: KickTracker.Metrics.Sessionizer.norm(DateTime.utc_now())
end
