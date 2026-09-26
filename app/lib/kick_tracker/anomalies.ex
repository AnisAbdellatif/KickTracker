defmodule KickTracker.Anomalies do
  @moduledoc """
  Audience anomalies for the admin pages (project.md §19.4): each stream's
  findings from `Metrics.Anomalies`, against the channel's own earlier
  streams. Read-only, and computed when asked: nothing is stored, so a
  change to the rules shows at once on every stream.

  A stream's baseline is its channel's `@baseline_streams` streams before
  it that have ended and aren't excluded (an admin excluded them as not
  representative). Streams merged into another count as part of it.
  """

  alias KickTracker.Channels.Channel
  alias KickTracker.Metrics.Anomalies, as: Rules
  alias KickTracker.Metrics.Coverage
  alias KickTracker.{Repo, Reports, Series}

  @baseline_streams 30
  # The chat source's cadence, as `Series` pads it.
  @chat_pad_s 60

  @type result :: %{
          stream: map(),
          profile: Rules.profile(),
          baseline: Rules.baseline(),
          findings: [Rules.finding()],
          level: :none | :some | :several
        }

  @doc "A channel's latest `limit` streams with their findings, newest first."
  @spec channel_streams(Channel.t(), pos_integer()) :: [result()]
  def channel_streams(%Channel{} = channel, limit \\ 30) do
    channel
    |> Reports.streams(limit: limit + @baseline_streams)
    |> Enum.reverse()
    |> evaluate(channel)
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  @doc "One stream's findings, or nil when there is no such stream."
  @spec stream(Channel.t(), integer()) :: result() | nil
  def stream(%Channel{} = channel, stream_id) do
    case Reports.stream(stream_id) do
      %{channel_id: id, merged_into: nil} = stream when id == channel.id ->
        channel
        |> Reports.streams(
          to: DateTime.add(stream.started_at, 1),
          limit: @baseline_streams + 1
        )
        |> Enum.reverse()
        |> evaluate(channel)
        |> Enum.find(&(&1.stream.id == stream_id))

      _ ->
        nil
    end
  end

  # Streams oldest first: each one's result, with the baseline of the
  # streams before it.
  defp evaluate([], _channel), do: []

  defp evaluate(streams, channel) do
    inputs = inputs(channel, streams)

    streams
    |> Enum.zip(inputs)
    |> Enum.map_reduce([], fn {stream, input}, earlier ->
      profile = Rules.profile(input)
      baseline = Rules.baseline(Enum.take(earlier, @baseline_streams))
      findings = Rules.findings(input, baseline)

      result = %{
        stream: stream,
        profile: profile,
        baseline: baseline,
        findings: findings,
        level: Rules.level(findings)
      }

      # Only ended, representative streams make the baseline.
      earlier =
        if stream.ended_at && not stream.excluded?, do: [profile | earlier], else: earlier

      {result, earlier}
    end)
    |> elem(0)
  end

  # What the rules read, for each stream, from a few queries over the
  # whole range.
  defp inputs(channel, streams) do
    from = hd(streams).started_at
    to = DateTime.add(List.last(streams).ended_at || DateTime.utc_now(), 60)
    ids = Enum.map(streams, & &1.id)
    samples = samples(channel.id, ids, from, to)
    chat = chat(channel.id, from, to)
    periods = Series.periods(channel.id, "chat", from, to)
    hosts = hosts(channel.id, from, to)
    previous_ends = [nil | Enum.map(streams, & &1.ended_at)]

    streams
    |> Enum.zip(previous_ends)
    |> Enum.map(fn {s, previous_ended_at} ->
      until = s.ended_at || DateTime.utc_now()

      %{
        started_at: s.started_at,
        ended_at: s.ended_at,
        viewers: Map.get(samples, s.id, []),
        chat: chat,
        chat_gaps: Coverage.gaps(periods, s.started_at, until, @chat_pad_s),
        hosts: hosts,
        follows: s.follows,
        hours_watched: s.hours_watched,
        previous_ended_at: previous_ended_at
      }
    end)
  end

  # Viewer readings by stream; a merged part's readings go to its root.
  defp samples(channel_id, ids, from, to) do
    Repo.query!(
      """
      SELECT coalesce(g.root_id, v.stream_id), v.observed_at, v.viewers
      FROM viewer_samples v
      LEFT JOIN merge_groups g ON g.stream_id = v.stream_id AND g.root_id <> v.stream_id
      WHERE v.channel_id = $1 AND v.observed_at >= $2 AND v.observed_at < $3
        AND coalesce(g.root_id, v.stream_id) = ANY($4)
      """,
      [channel_id, from, to, ids]
    ).rows
    |> Enum.group_by(&hd/1, fn [_, at, v] -> {at, v} end)
  end

  defp chat(channel_id, from, to) do
    Repo.query!(
      """
      SELECT extract(epoch FROM minute)::bigint, chatters FROM chat_minutes
      WHERE channel_id = $1 AND minute >= $2 AND minute < $3
      """,
      [channel_id, DateTime.add(from, -60), to]
    ).rows
    |> Map.new(fn [minute, chatters] -> {minute, chatters} end)
  end

  defp hosts(channel_id, from, to) do
    Repo.query!(
      """
      SELECT occurred_at, kind FROM channel_events
      WHERE channel_id = $1 AND kind IN ('hosted_by', 'hosting')
        AND occurred_at >= $2 AND occurred_at < $3
      """,
      [channel_id, DateTime.add(from, -600), to]
    ).rows
    |> Enum.map(fn
      [at, "hosted_by"] -> {at, :hosted_by}
      [at, "hosting"] -> {at, :hosting}
    end)
  end
end
