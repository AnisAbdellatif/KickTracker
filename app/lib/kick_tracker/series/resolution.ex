defmodule KickTracker.Series.Resolution do
  @moduledoc """
  Resolution by range (project.md §13.4): the server picks the bucket from
  the requested range so no series exceeds about 2 000 points. Pure.

  | Range      | Bucket                  |
  |------------|-------------------------|
  | ≤ 12 hours | raw 60s samples         |
  | ≤ 7 days   | 5 minutes               |
  | ≤ 90 days  | 1 hour                  |
  | longer     | 1 day, channel timezone |

  Daily buckets stay under 2 000 points for five and a half years of
  history; past that, weekly buckets will be needed.
  """

  @type t :: :raw | :m5 | :hour | :day

  @hour 3600
  @day 86_400

  @doc """
  The resolution for a range, in seconds of span.

      iex> KickTracker.Series.Resolution.for_span(6 * 3600)
      :raw
      iex> KickTracker.Series.Resolution.for_span(3 * 86_400)
      :m5
      iex> KickTracker.Series.Resolution.for_span(30 * 86_400)
      :hour
      iex> KickTracker.Series.Resolution.for_span(365 * 86_400)
      :day
  """
  @spec for_span(non_neg_integer()) :: t()
  def for_span(span_s) when span_s <= 12 * @hour, do: :raw
  def for_span(span_s) when span_s <= 7 * @day, do: :m5
  def for_span(span_s) when span_s <= 90 * @day, do: :hour
  def for_span(_span_s), do: :day

  @doc """
  The range's resolution. A `requested` one is honoured only when it gives
  no more points than the automatic one.
  """
  @spec choose(DateTime.t(), DateTime.t(), t() | nil) :: t()
  def choose(from, to, requested \\ nil) do
    auto = for_span(max(DateTime.diff(to, from), 0))
    if requested && rank(requested) >= rank(auto), do: requested, else: auto
  end

  defp rank(:raw), do: 0
  defp rank(:m5), do: 1
  defp rank(:hour), do: 2
  defp rank(:day), do: 3

  @doc "Bucket width in seconds (nil for raw, whose points are the samples)."
  @spec width_s(t()) :: pos_integer() | nil
  def width_s(:raw), do: nil
  def width_s(:m5), do: 300
  def width_s(:hour), do: @hour
  def width_s(:day), do: @day

  @doc "The name sent to the browser."
  @spec name(t()) :: String.t()
  def name(:raw), do: "raw"
  def name(:m5), do: "5m"
  def name(:hour), do: "1h"
  def name(:day), do: "1d"

  @doc "Parses a name from a query string."
  @spec parse(String.t() | nil) :: t() | nil
  def parse("raw"), do: :raw
  def parse("5m"), do: :m5
  def parse("1h"), do: :hour
  def parse("1d"), do: :day
  def parse(_), do: nil

  @doc """
  Every bucket start in `[from, to)`, as unix seconds, for a fixed-width
  resolution: the grid a series is laid on so an empty bucket is `nil`.
  Buckets are aligned to the epoch (UTC), like TimescaleDB's `time_bucket`.
  """
  @spec grid(DateTime.t(), DateTime.t(), :m5 | :hour) :: [integer()]
  def grid(from, to, res) when res in [:m5, :hour] do
    w = width_s(res)
    first = div(DateTime.to_unix(from), w) * w
    last = DateTime.to_unix(to) - 1
    if last < first, do: [], else: Enum.to_list(first..last//w)
  end

  @doc """
  Lays `{t, value, ...}` rows on a grid: one column per value, `nil` where a
  bucket has no row. Rows off the grid are dropped.
  """
  @spec fill([integer()], [tuple()], pos_integer()) :: [[term()]]
  def fill(grid, rows, ncols) do
    by_t = Map.new(rows, fn row -> {elem(row, 0), row} end)
    empty = List.duplicate(nil, ncols)

    rows =
      Enum.map(grid, fn t ->
        case by_t[t] do
          nil -> empty
          row -> row |> Tuple.to_list() |> tl()
        end
      end)

    if rows == [],
      do: List.duplicate([], ncols),
      else: rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
  end

  @doc """
  Raw samples (`{t, value}`, sorted) with a `nil` inserted wherever two
  samples are more than `max_gap_s` apart, so a line breaks instead of
  bridging a gap (§13.1).
  """
  @spec break_gaps([{integer(), term()}], pos_integer()) :: {[integer()], [term()]}
  def break_gaps(samples, max_gap_s) do
    {points, _} =
      Enum.flat_map_reduce(samples, nil, fn {t, v}, prev ->
        if prev && t - prev > max_gap_s,
          do: {[{prev + div(t - prev, 2), nil}, {t, v}], t},
          else: {[{t, v}], t}
      end)

    {Enum.map(points, &elem(&1, 0)), Enum.map(points, &elem(&1, 1))}
  end
end
