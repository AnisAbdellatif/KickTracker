defmodule Sim.Curve do
  @moduledoc """
  How a simulated stream's numbers move: viewers over its length, and how
  much chat that audience produces. Pure and deterministic from the
  channel's seed, so the same stream always looks the same.

  Viewer counts change **once a minute**, because that is how often Kick
  refreshes its own (§2.1): a tracker polling faster must see the same value
  repeated, exactly as it would in the real thing.
  """

  alias Sim.Scenario.Channel

  # Follower growth is counted from here, so a channel's total stays close
  # to what the scenario asked for rather than drifting with the epoch.
  @followers_from ~U[2026-01-01 00:00:00Z]

  @doc """
  Viewers `elapsed_s` into a stream of `duration_s`: a ramp-up, a long
  plateau that drifts, and a decline towards the end.
  """
  @spec viewers(Channel.t(), integer(), pos_integer()) :: pos_integer()
  def viewers(%Channel{} = channel, elapsed_s, duration_s) do
    minute = div(max(elapsed_s, 0), 60)
    progress = min(minute * 60 / duration_s, 1.0)

    base = channel.peak_viewers * shape(progress) * wave(channel.seed, progress)
    max(1, round(base * (1 + noise(channel.seed, minute, 0.12))))
  end

  @doc "Chat messages sent during the minute starting `elapsed_s` into the stream."
  @spec messages_per_minute(Channel.t(), pos_integer(), integer()) :: non_neg_integer()
  def messages_per_minute(%Channel{chat: chat, seed: seed}, viewers, elapsed_s) do
    minute = div(max(elapsed_s, 0), 60)
    base = viewers * chat.messages_per_viewer_per_min
    max(0, round(base * (1 + noise(seed + 1, minute, 0.4))))
  end

  @doc """
  Who chatted during that minute, as chatter ids drawn from the channel's
  pool. The same ids come back within a stream and across streams, so
  "returning chatters" means something.
  """
  @spec chatters(Channel.t(), non_neg_integer(), integer()) :: [pos_integer()]
  def chatters(%Channel{} = channel, messages, elapsed_s) do
    count = round(messages / channel.chat.messages_per_chatter)
    minute = div(max(elapsed_s, 0), 60)
    pool = pool_size(channel)

    1..max(count, 0)//1
    |> Enum.map(fn n ->
      channel.user_id + 1 + rem(:erlang.phash2({channel.seed, minute, n}), pool)
    end)
    |> Enum.uniq()
  end

  @doc "How many different people can ever chat in this channel."
  @spec pool_size(Channel.t()) :: pos_integer()
  def pool_size(%Channel{} = channel),
    do: max(round(channel.peak_viewers * channel.chat.pool_factor), 10)

  @doc """
  Followers at `at`: a slow climb from the channel's starting count, never
  going backwards. Growth is counted from a fixed recent date, not from the
  Unix epoch, so the totals stay in proportion to the channel.
  """
  @spec followers(Channel.t(), DateTime.t()) :: pos_integer()
  def followers(%Channel{} = channel, at) do
    days = at |> DateTime.diff(@followers_from, :second) |> max(0) |> div(86_400)
    channel.followers + days * followers_per_day(channel)
  end

  @doc "How many followers this channel gains a day."
  @spec followers_per_day(Channel.t()) :: pos_integer()
  def followers_per_day(%Channel{} = channel) do
    growth = 1 + rem(:erlang.phash2({channel.seed, :growth}), 3)
    max(round(channel.peak_viewers / 100 * growth), 1)
  end

  # The audience arrives quickly, sits through the middle, and drifts away
  # at the end: 0.25 -> 1.0 over the first tenth, 1.0 -> 0.85 through the
  # middle, then down to 0.5 by the end.
  defp shape(p) when p < 0.1, do: 0.25 + 0.75 * :math.pow(p / 0.1, 0.6)
  defp shape(p) when p < 0.75, do: 1.0 - 0.15 * ((p - 0.1) / 0.65)
  defp shape(p), do: 0.85 - 0.35 * ((p - 0.75) / 0.25)

  # A slow swell over the stream, so the plateau isn't a straight line.
  defp wave(seed, p) do
    phase = rem(:erlang.phash2({seed, :wave}), 628) / 100
    1 + 0.06 * :math.sin(p * 6 * :math.pi() + phase)
  end

  # Deterministic jitter in -spread/2..+spread/2.
  defp noise(seed, n, spread) do
    (rem(:erlang.phash2({seed, n}), 1000) / 1000 - 0.5) * spread
  end
end
