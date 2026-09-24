defmodule KickTracker.Metrics.Coverage do
  @moduledoc """
  How much of a window a source covered, from its `coverage` periods
  (project.md §12.5). Pure.

  A period's outcomes vouch for the time from its first outcome to its
  last plus one cadence (`pad_s`): a poll at 12:00 says 12:00–12:01 was
  observed. Periods that failed (`ok: false`) cover nothing, and time no
  period covers is a gap, so the fraction never counts what we didn't see.
  """

  @type period :: %{from_at: DateTime.t(), to_at: DateTime.t(), ok: boolean()}

  @doc """
  The covered fraction of `[from, to)`, between 0.0 and 1.0.

      iex> at = ~U[2026-01-01 00:00:00Z]
      iex> periods = [%{from_at: at, to_at: DateTime.add(at, 1740), ok: true}]
      iex> KickTracker.Metrics.Coverage.fraction(periods, at, DateTime.add(at, 3600), 60)
      0.5
  """
  @spec fraction([period()], DateTime.t(), DateTime.t(), non_neg_integer()) :: float()
  def fraction(periods, from, to, pad_s) do
    window = DateTime.diff(to, from, :millisecond)

    if window <= 0 do
      0.0
    else
      covered =
        periods
        |> Enum.filter(& &1.ok)
        |> Enum.map(fn p ->
          {max(ms(p.from_at), ms(from)), min(ms(p.to_at) + pad_s * 1000, ms(to))}
        end)
        |> Enum.filter(fn {a, b} -> b > a end)
        |> Enum.sort()
        |> merge([])
        |> Enum.map(fn {a, b} -> b - a end)
        |> Enum.sum()

      covered / window
    end
  end

  @doc "The uncovered stretches of `[from, to)`, as `{from, to}` pairs, oldest first."
  @spec gaps([period()], DateTime.t(), DateTime.t(), non_neg_integer()) ::
          [{DateTime.t(), DateTime.t()}]
  def gaps(periods, from, to, pad_s) do
    covered =
      periods
      |> Enum.filter(& &1.ok)
      |> Enum.map(fn p ->
        {max(ms(p.from_at), ms(from)), min(ms(p.to_at) + pad_s * 1000, ms(to))}
      end)
      |> Enum.filter(fn {a, b} -> b > a end)
      |> Enum.sort()
      |> merge([])

    {gaps, cursor} =
      Enum.reduce(covered, {[], ms(from)}, fn {a, b}, {acc, cursor} ->
        acc = if a > cursor, do: [{cursor, a} | acc], else: acc
        {acc, max(cursor, b)}
      end)

    gaps = if cursor < ms(to), do: [{cursor, ms(to)} | gaps], else: gaps

    gaps
    |> Enum.reverse()
    |> Enum.map(fn {a, b} -> {dt(a), dt(b)} end)
  end

  defp merge([], acc), do: Enum.reverse(acc)

  defp merge([{a, b} | rest], [{pa, pb} | acc]) when a <= pb,
    do: merge(rest, [{pa, max(b, pb)} | acc])

  defp merge([interval | rest], acc), do: merge(rest, [interval | acc])

  defp ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
end
