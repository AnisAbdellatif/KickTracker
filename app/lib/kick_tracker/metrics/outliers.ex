defmodule KickTracker.Metrics.Outliers do
  @moduledoc """
  Viewer readings that look like glitches (project.md §19.2): a sudden 0
  in the middle of a stream, or a single reading far above both of its
  neighbours. Pure.

  Flagged readings are never deleted or changed: they stay in
  `viewer_samples`, are recorded in `viewer_flags`, and are left out of
  peaks, where one bad reading would otherwise become the stream's record.
  Averages and hours watched keep them (one reading moves those very
  little).

  Only a reading between two others no more than `@max_gap_s` apart is
  judged: at a stream's edges or across a gap there is nothing to compare.
  """

  @max_gap_s 150
  # A zero counts as a glitch only when the neighbours are an audience.
  @zero_floor 20
  # A spike: above `@spike_ratio` × the higher neighbour, and by at least
  # `@spike_floor` viewers, with neighbours that agree (within `@steady`).
  @spike_ratio 2.0
  @spike_floor 50
  @steady 0.5

  @type reason :: :zero | :spike

  @doc """
  The flagged readings among one stream's samples (`{observed_at,
  viewers}`, any order), as `{observed_at, reason}`, oldest first.
  """
  @spec flags([{DateTime.t(), non_neg_integer()}]) :: [{DateTime.t(), reason()}]
  def flags(samples) do
    samples
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.flat_map(fn [{a, prev}, {at, v}, {b, next}] ->
      close? = DateTime.diff(at, a) <= @max_gap_s and DateTime.diff(b, at) <= @max_gap_s

      case close? && judge(prev, v, next) do
        reason when reason in [:zero, :spike] -> [{at, reason}]
        _ -> []
      end
    end)
  end

  defp judge(prev, 0, next) when prev >= @zero_floor and next >= @zero_floor, do: :zero

  defp judge(prev, v, next) do
    high = max(prev, next)
    low = min(prev, next)

    if high > 0 and low >= high * (1 - @steady) and v > high * @spike_ratio and
         v - high >= @spike_floor,
       do: :spike,
       else: nil
  end
end
