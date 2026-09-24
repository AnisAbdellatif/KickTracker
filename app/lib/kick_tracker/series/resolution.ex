defmodule KickTracker.Series.Resolution do
  @moduledoc """
  Resolution by range (project.md §13.4): the server picks the bucket from
  the requested range so no series exceeds 2 000 points. Pure.

  | Range       | Bucket                   | Points at most |
  |-------------|--------------------------|----------------|
  | ≤ 12 hours  | raw 60s samples          | ~720           |
  | ≤ 6 days    | 5 minutes                | 1 728          |
  | ≤ 20 days   | 15 minutes               | 1 920          |
  | ≤ 80 days   | 1 hour                   | 1 920          |
  | ≤ 200 days  | 6 hours                  | 800            |
  | < 2000 days | 1 day, channel timezone  | 2 000          |
  | longer      | 1 week, channel timezone | 1 044 for the 20 years a range may span |

  The presets land on: 24h → 5 min, 7d → 15 min, 30d → 1 h, 90d → 6 h,
  1y → 1 day.
  """

  @type t :: :raw | :m5 | :m15 | :hour | :h6 | :day | :week

  @hour 3600
  @day 86_400

  @doc "The most points a series may have."
  def max_points, do: 2_000

  @doc """
  The resolution for a range, in seconds of span.

      iex> KickTracker.Series.Resolution.for_span(6 * 3600)
      :raw
      iex> KickTracker.Series.Resolution.for_span(3 * 86_400)
      :m5
      iex> KickTracker.Series.Resolution.for_span(7 * 86_400)
      :m15
      iex> KickTracker.Series.Resolution.for_span(30 * 86_400)
      :hour
      iex> KickTracker.Series.Resolution.for_span(90 * 86_400)
      :h6
      iex> KickTracker.Series.Resolution.for_span(365 * 86_400)
      :day
      iex> KickTracker.Series.Resolution.for_span(20 * 365 * 86_400)
      :week
  """
  @spec for_span(non_neg_integer()) :: t()
  def for_span(span_s) when span_s <= 12 * @hour, do: :raw
  def for_span(span_s) when span_s <= 6 * @day, do: :m5
  def for_span(span_s) when span_s <= 20 * @day, do: :m15
  def for_span(span_s) when span_s <= 80 * @day, do: :hour
  def for_span(span_s) when span_s <= 200 * @day, do: :h6
  def for_span(span_s) when span_s <= 1999 * @day, do: :day
  def for_span(_span_s), do: :week

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
  defp rank(:m15), do: 2
  defp rank(:hour), do: 3
  defp rank(:h6), do: 4
  defp rank(:day), do: 5
  defp rank(:week), do: 6

  @doc "Bucket width in seconds (nil for raw, whose points are the samples; nominal for day and week)."
  @spec width_s(t()) :: pos_integer() | nil
  def width_s(:raw), do: nil
  def width_s(:m5), do: 300
  def width_s(:m15), do: 900
  def width_s(:hour), do: @hour
  def width_s(:h6), do: 6 * @hour
  def width_s(:day), do: @day
  def width_s(:week), do: 7 * @day

  @doc "Whether buckets follow the channel's timezone (days and weeks) rather than UTC."
  @spec local?(t()) :: boolean()
  def local?(res), do: res in [:day, :week]

  @doc "The name sent to the browser."
  @spec name(t()) :: String.t()
  def name(:raw), do: "raw"
  def name(:m5), do: "5m"
  def name(:m15), do: "15m"
  def name(:hour), do: "1h"
  def name(:h6), do: "6h"
  def name(:day), do: "1d"
  def name(:week), do: "1w"

  @doc "Parses a name from a query string."
  @spec parse(String.t() | nil) :: t() | nil
  def parse("raw"), do: :raw
  def parse("5m"), do: :m5
  def parse("15m"), do: :m15
  def parse("1h"), do: :hour
  def parse("6h"), do: :h6
  def parse("1d"), do: :day
  def parse("1w"), do: :week
  def parse(_), do: nil

  @doc """
  Every bucket start in `[from, to)`, as unix seconds, for a fixed-width
  resolution: the grid a series is laid on so an empty bucket is `nil`.
  Buckets are aligned to the epoch (UTC), like TimescaleDB's `time_bucket`.
  """
  @spec grid(DateTime.t(), DateTime.t(), :m5 | :m15 | :hour | :h6) :: [integer()]
  def grid(from, to, res) when res in [:m5, :m15, :hour, :h6] do
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
