defmodule KickTracker.Collector.BackfillPlan do
  @moduledoc """
  Which time ranges to fill from the shadow collector (project.md §10.5),
  pure: for one channel and one source, the parts of a window the shadow
  covered and we didn't.

  A coverage period `{from, to}` of working outcomes vouches for
  `[from, to + pad]` (one cadence past its last outcome, as the health
  page counts it). Ranges shorter than `min_s` are left alone: a gap that
  small is a late poll, not a hole.
  """

  @type range :: {DateTime.t(), DateTime.t()}

  @doc "The ranges in `window` covered by `shadow` periods and not by `ours`."
  @spec fill(range(), [range()], [range()], non_neg_integer(), pos_integer()) :: [range()]
  def fill({w_from, w_to}, ours, shadow, pad_s, min_s) do
    pad = fn periods -> Enum.map(periods, fn {a, b} -> {a, DateTime.add(b, pad_s)} end) end

    shadow
    |> pad.()
    |> clip({w_from, w_to})
    |> merge()
    |> subtract(ours |> pad.() |> merge())
    |> Enum.filter(fn {a, b} -> DateTime.diff(b, a) >= min_s end)
  end

  @doc "Overlapping or touching ranges joined, sorted."
  @spec merge([range()]) :: [range()]
  def merge(ranges) do
    ranges
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.reduce([], fn
      {a, b}, [{pa, pb} | rest] ->
        if DateTime.compare(a, pb) != :gt,
          do: [{pa, max_dt(pb, b)} | rest],
          else: [{a, b}, {pa, pb} | rest]

      r, [] ->
        [r]
    end)
    |> Enum.reverse()
  end

  defp clip(ranges, {w_from, w_to}) do
    for {a, b} <- ranges,
        a = max_dt(a, w_from),
        b = min_dt(b, w_to),
        DateTime.before?(a, b),
        do: {a, b}
  end

  # `ranges` minus `holes`, both merged and sorted.
  defp subtract(ranges, holes) do
    Enum.flat_map(ranges, fn range ->
      Enum.reduce(holes, [range], fn hole, pieces -> Enum.flat_map(pieces, &cut(&1, hole)) end)
    end)
  end

  # A range with a hole cut out of it: zero, one or two pieces.
  defp cut({a, b}, {ha, hb}) do
    if DateTime.before?(ha, b) and DateTime.before?(a, hb),
      do: Enum.filter([{a, ha}, {hb, b}], fn {x, y} -> DateTime.before?(x, y) end),
      else: [{a, b}]
  end

  defp max_dt(a, b), do: if(DateTime.after?(a, b), do: a, else: b)
  defp min_dt(a, b), do: if(DateTime.before?(a, b), do: a, else: b)
end
