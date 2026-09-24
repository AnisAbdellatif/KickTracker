defmodule Sim.StreamState do
  @moduledoc """
  What a simulated stream is showing at a given moment: its title and
  category, and where those change. Pure and derived from the channel's
  seed and the stream's start, so the same stream always tells the same
  story.

  A stream is cut into one to three segments; each has its own category and
  title. That is what gives a tracker something to detect: the category
  switches Kick announces with `livestream.metadata.updated`, and the
  viewer change that follows.
  """

  alias Sim.Scenario.Channel
  alias Sim.Schedule

  @type segment :: %{
          from: DateTime.t(),
          to: DateTime.t(),
          category: map(),
          title: String.t(),
          index: non_neg_integer()
        }

  @doc "The segments of one stream, in order."
  @spec segments(Channel.t(), Schedule.window()) :: [segment()]
  def segments(%Channel{} = channel, window) do
    count = segment_count(channel, window)
    length_s = div(window.duration_s, count)

    for index <- 0..(count - 1) do
      from = DateTime.add(window.started_at, index * length_s, :second)
      to = if index == count - 1, do: window.ends_at, else: DateTime.add(from, length_s, :second)

      %{
        from: from,
        to: to,
        index: index,
        category: pick(channel.categories, channel.seed, window, index, :category),
        title: pick(channel.titles, channel.seed, window, index, :title)
      }
    end
  end

  @doc """
  The segment running at `at`, or the last one if `at` is past the end.
  A title or category set by hand (the control API) replaces the
  segment's from that moment on, without changing where segments start.
  """
  @spec at(Channel.t(), Schedule.window(), DateTime.t()) :: segment()
  def at(%Channel{} = channel, window, at) do
    segments = segments(channel, window)

    segment =
      Enum.find(segments, List.last(segments), fn segment ->
        DateTime.compare(at, segment.from) != :lt and DateTime.compare(at, segment.to) == :lt
      end)

    channel.overrides.metadata
    |> Enum.filter(fn o ->
      DateTime.compare(o.window_started_at, window.started_at) == :eq and
        DateTime.compare(o.at, at) != :gt
    end)
    |> Enum.sort_by(& &1.at, DateTime)
    |> Enum.reduce(segment, fn o, segment ->
      segment
      |> then(&if(o[:title], do: %{&1 | title: o.title}, else: &1))
      |> then(&if(o[:category], do: %{&1 | category: o.category}, else: &1))
    end)
  end

  @doc """
  The moments inside a stream where the title or category changes, with the
  segment that starts there. The first segment is not a change.
  """
  @spec changes(Channel.t(), Schedule.window()) :: [segment()]
  def changes(%Channel{} = channel, window), do: channel |> segments(window) |> Enum.drop(1)

  defp segment_count(channel, window) do
    1 + rem(:erlang.phash2({channel.seed, DateTime.to_unix(window.started_at)}), 3)
  end

  defp pick(options, seed, window, index, what) do
    n = :erlang.phash2({seed, DateTime.to_unix(window.started_at), index, what})
    Enum.at(options, rem(n, length(options)))
  end
end
