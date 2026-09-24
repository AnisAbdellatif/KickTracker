defmodule KickTracker.Metrics do
  @moduledoc """
  The formulas behind every figure (project.md §4.2, §14). Pure: the
  reference definitions, heavily tested; the SQL rollups
  (`KickTracker.Rollups`) must agree with them.

  **Hours watched** = Σ viewers × weight, where a sample's weight is the
  time since the previous sample of the same stream (for the first sample,
  since the stream's start), **capped at 75 seconds**. Kick refreshes its
  viewer count about every 60s and we poll every 60s: 75s tolerates a poll
  a little late, and a missed poll (a gap of 120s) adds at most 15s, never
  an interpolated minute. The weight looks backwards so that each sample's
  contribution falls in the hour it was taken, and hourly figures add up
  to the stream's.
  """

  @cap_s 75

  @doc "The weight cap in seconds."
  def cap_s, do: @cap_s

  @doc """
  Hours watched for one stream's samples (`{observed_at, viewers}`, any
  order), given its start.
  """
  @spec hours_watched(DateTime.t(), [{DateTime.t(), non_neg_integer()}]) :: float()
  def hours_watched(started_at, samples) do
    samples
    |> weighted(started_at)
    |> Enum.reduce(0.0, fn {_at, viewers, weight_s}, acc -> acc + viewers * weight_s / 3600 end)
  end

  @doc """
  Each sample with its weight in seconds, oldest first:
  `{observed_at, viewers, weight_s}`.
  """
  @spec weighted([{DateTime.t(), non_neg_integer()}], DateTime.t()) ::
          [{DateTime.t(), non_neg_integer(), number()}]
  def weighted(samples, started_at) do
    samples
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.map_reduce(started_at, fn {at, viewers}, previous ->
      gap = max(DateTime.diff(at, previous, :microsecond) / 1_000_000, 0)
      {{at, viewers, min(gap, @cap_s)}, at}
    end)
    |> elem(0)
  end

  @doc """
  Average and peak viewers, and how many samples: `nil` averages and peaks
  when there are none (no data is not zero viewers).
  """
  @spec viewers([{DateTime.t(), non_neg_integer()}]) :: %{
          samples: non_neg_integer(),
          avg: float() | nil,
          peak: non_neg_integer() | nil
        }
  def viewers([]), do: %{samples: 0, avg: nil, peak: nil}

  def viewers(samples) do
    counts = Enum.map(samples, &elem(&1, 1))
    %{samples: length(counts), avg: Enum.sum(counts) / length(counts), peak: Enum.max(counts)}
  end

  # A follower reading counts for a stream's start or end if it was taken
  # within this long of it (readings are queued at the start and the end).
  @follower_window_s 30 * 60

  @doc """
  Follower totals at a stream's start and end, and the gain, from the
  readings (`{observed_at, followers}`) around it: the reading closest to
  the start, and the one closest to the end, each within 30 minutes. Any
  of the three is nil when not known.
  """
  @spec follower_gain(DateTime.t(), DateTime.t() | nil, [{DateTime.t(), non_neg_integer()}]) ::
          %{start: integer() | nil, end: integer() | nil, gain: integer() | nil}
  def follower_gain(started_at, ended_at, readings) do
    first = closest(readings, started_at)
    last = ended_at && closest(readings, ended_at)
    # The same reading can't be both.
    last = if last && first && elem(last, 0) == elem(first, 0), do: nil, else: last

    start_count = first && elem(first, 1)
    end_count = last && elem(last, 1)
    gain = if start_count && end_count, do: end_count - start_count

    %{start: start_count, end: end_count, gain: gain}
  end

  defp closest(readings, at) do
    readings
    |> Enum.filter(fn {t, _} -> abs(DateTime.diff(t, at)) <= @follower_window_s end)
    |> Enum.min_by(fn {t, _} -> abs(DateTime.diff(t, at)) end, fn -> nil end)
  end

  @doc "Seconds a stream lasted; nil while it is live."
  @spec airtime_s(DateTime.t(), DateTime.t() | nil) :: non_neg_integer() | nil
  def airtime_s(_started_at, nil), do: nil
  def airtime_s(started_at, ended_at), do: max(DateTime.diff(ended_at, started_at), 0)
end
