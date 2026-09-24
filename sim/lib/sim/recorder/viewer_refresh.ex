defmodule Sim.Recorder.ViewerRefresh do
  @moduledoc """
  Answers "how often does Kick refresh `viewer_count`?" (project.md §16) from a
  series of polls of one channel. Pure.

  A change is a sample whose count differs from the previous sample's. The
  time between consecutive changes estimates Kick's refresh interval; it can't
  be measured more finely than the polling interval.
  """

  @type sample :: %{at_ms: integer(), viewers: integer() | nil}

  @spec summarize([sample()]) :: map()
  def summarize(samples) do
    samples = samples |> Enum.reject(&is_nil(&1.viewers)) |> Enum.sort_by(& &1.at_ms)

    change_times =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [a, b] -> if a.viewers != b.viewers, do: [b.at_ms], else: [] end)

    intervals =
      change_times
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> (b - a) / 1000 end)

    %{
      "samples" => length(samples),
      "changes" => length(change_times),
      "distinct_values" => samples |> Enum.map(& &1.viewers) |> Enum.uniq() |> length(),
      "seconds_between_changes" => stats(intervals)
    }
  end

  defp stats([]), do: nil

  defp stats(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    median =
      if rem(n, 2) == 1,
        do: Enum.at(sorted, div(n, 2)),
        else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2

    %{"min" => hd(sorted), "median" => median, "max" => List.last(sorted), "count" => n}
  end
end
