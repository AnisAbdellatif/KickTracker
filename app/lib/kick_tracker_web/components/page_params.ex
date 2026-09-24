defmodule KickTrackerWeb.PageParams do
  @moduledoc """
  Query params of the public pages, made safe to use (project.md §13.2:
  every page is reproducible from its URL, so its URL is also where
  anything can be typed).

  `clean/1` keeps only string values: `?period[a]=1` or `?c[]=a` arrive as
  maps and lists, which would otherwise reach `String.split/3`,
  `Integer.parse/1` or `URI.encode_query/1` and fail the page. A param
  that isn't a string is simply dropped, as if it wasn't given.

  `custom_range/3` turns the period picker's two dates, read in a
  timezone, into the `from`/`to` params of a custom range; `dates/2` is
  the other way, for showing a custom range in the picker.
  """

  alias KickTrackerWeb.Period

  use Gettext, backend: KickTrackerWeb.Gettext

  @max_days 20 * 365

  @doc "Only the params whose key and value are strings."
  @spec clean(map()) :: %{String.t() => String.t()}
  def clean(params) when is_map(params) do
    for {k, v} <- params, is_binary(k), is_binary(v), into: %{}, do: {k, v}
  end

  def clean(_), do: %{}

  @doc """
  The `from` and `to` params (unix seconds, as strings) of the days
  `from` to `to`, both included, in `tz`: from the start of the first day
  to the start of the day after the last. `{:error, message}` for a date
  that isn't one, a range that ends before it starts, starts after today,
  or is longer than a period may be.
  """
  @spec custom_range(term(), term(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def custom_range(from, to, tz \\ "Etc/UTC") do
    with {:ok, from} <- date(from),
         {:ok, to} <- date(to),
         :ok <- check(from, to, today(tz)) do
      {a, b} = bounds(from, Date.add(to, 1), tz)
      {:ok, %{"from" => Integer.to_string(a), "to" => Integer.to_string(b)}}
    end
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, d} -> {:ok, d}
      _ -> {:error, gettext("Pick a start and an end date.")}
    end
  end

  defp date(_), do: {:error, gettext("Pick a start and an end date.")}

  defp check(from, to, today) do
    cond do
      Date.compare(from, to) == :gt ->
        {:error, gettext("The range has to start before it ends.")}

      Date.compare(from, today) == :gt ->
        {:error, gettext("The range has to start today or earlier.")}

      Date.diff(to, from) > @max_days ->
        {:error, gettext("The range can be at most 20 years long.")}

      true ->
        :ok
    end
  end

  @doc "The first and last day of a custom period, in `tz` (ISO 8601 strings)."
  @spec dates(Period.t(), String.t()) :: {String.t(), String.t()}
  def dates(%Period{from: from, to: to}, tz \\ "Etc/UTC") do
    {a, b} = local_dates(from, DateTime.add(to, -1), tz)
    {Date.to_iso8601(a), Date.to_iso8601(b)}
  end

  # Midnights and dates in a timezone. Elixir has no timezone database
  # here; PostgreSQL has one, so a channel's timezone is read there.
  defp utc?(tz), do: tz in [nil, "", "Etc/UTC", "UTC"]

  defp today(tz) do
    if utc?(tz),
      do: Date.utc_today(),
      else: elem(local_dates(DateTime.utc_now(), DateTime.utc_now(), tz), 0)
  end

  defp bounds(a, b, tz) do
    if utc?(tz) do
      {unix(a), unix(b)}
    else
      [[x, y]] =
        KickTracker.Repo.query!(
          """
          SELECT extract(epoch FROM ($1::date::timestamp AT TIME ZONE $3))::bigint,
                 extract(epoch FROM ($2::date::timestamp AT TIME ZONE $3))::bigint
          """,
          [a, b, tz]
        ).rows

      {x, y}
    end
  end

  defp local_dates(a, b, tz) do
    if utc?(tz) do
      {DateTime.to_date(a), DateTime.to_date(b)}
    else
      [[x, y]] =
        KickTracker.Repo.query!(
          "SELECT ($1::timestamptz AT TIME ZONE $3)::date, ($2::timestamptz AT TIME ZONE $3)::date",
          [a, b, tz]
        ).rows

      {x, y}
    end
  end

  defp unix(%Date{} = d), do: d |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix()
end
