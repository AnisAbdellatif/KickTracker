defmodule KickTrackerWeb.Period do
  @moduledoc """
  The period a page or a data request covers, from the query string, so
  every view is reproducible from its URL (project.md §13.2):

    * `period=24h|7d|30d|90d|1y|all` (default `30d`), ending now;
    * or `from` and `to`, as unix seconds or ISO 8601 (a custom range, at
      most 20 years long).

  A preset's `to` is now rounded up to the next whole minute, and its
  `from` is that minus the span, so every request within the same minute
  gets the same period: cache keys built from it (`KickTracker.Cache`)
  hit, and the range still reaches past the latest reading (`[from, to)`).
  """

  alias KickTracker.{Cache, Reports}

  @presets %{
    "24h" => 86_400,
    "7d" => 7 * 86_400,
    "30d" => 30 * 86_400,
    "90d" => 90 * 86_400,
    "1y" => 365 * 86_400
  }
  @max_span 20 * 365 * 86_400
  @align_s 60

  defstruct [:from, :to, :key]

  @type t :: %__MODULE__{from: DateTime.t(), to: DateTime.t(), key: String.t()}

  @doc "The period presets offered by the period picker, in order."
  def presets, do: ~w(24h 7d 30d 90d 1y all)

  @doc "The longest custom range, in seconds."
  def max_span_s, do: @max_span

  @doc """
  Parses the query params. `since` is where "all" starts (the channel's
  tracking start, or the first stream); without it, "all" starts when the
  earliest public channel's tracking began. Unparseable input falls back
  to the default rather than failing.
  """
  @spec parse(map(), keyword()) :: t()
  def parse(params, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> align()
    default = Keyword.get(opts, :default, "30d")

    with {:ok, from} <- time(params["from"]),
         {:ok, to} <- time(params["to"]),
         true <- DateTime.compare(from, to) == :lt,
         true <- DateTime.diff(to, from) <= @max_span do
      %__MODULE__{from: from, to: to, key: "custom"}
    else
      _ -> preset(params["period"] || default, now, opts, default)
    end
  end

  # Up to the next whole minute (a time already on one stays).
  defp align(at) do
    unix = DateTime.to_unix(at, :microsecond)
    step = @align_s * 1_000_000
    DateTime.from_unix!(div(unix + step - 1, step) * @align_s)
  end

  defp preset("all", now, opts, _default) do
    since = if Keyword.has_key?(opts, :since), do: opts[:since], else: earliest()

    from =
      (since && DateTime.truncate(since, :second)) || DateTime.add(now, -365, :day)

    from =
      cond do
        DateTime.compare(from, now) != :lt -> DateTime.add(now, -1, :day)
        DateTime.diff(now, from) > @max_span -> DateTime.add(now, -@max_span)
        true -> from
      end

    %__MODULE__{from: from, to: now, key: "all"}
  end

  defp preset(key, now, opts, default) do
    case @presets[key] do
      nil -> preset(default, now, opts, default)
      span -> %__MODULE__{from: DateTime.add(now, -span), to: now, key: key}
    end
  end

  # When the earliest public channel's tracking began: where "all" starts
  # on pages across channels. Cached; it only moves when channels change.
  defp earliest do
    Cache.fetch({:earliest_tracked_since}, 300, &Reports.earliest_tracked_since/0)
  end

  defp time(nil), do: :error
  defp time(unix) when is_integer(unix), do: DateTime.from_unix(unix)

  defp time(value) when is_binary(value) do
    case Integer.parse(value) do
      {unix, ""} ->
        DateTime.from_unix(unix)

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _} -> {:ok, DateTime.truncate(at, :second)}
          _ -> :error
        end
    end
  end

  defp time(_), do: :error

  @doc """
  How often a chart of this period fetches its data again, in seconds: a
  preset period ends now and moves; a custom range is fixed.
  """
  @spec refresh(t()) :: pos_integer() | nil
  def refresh(%__MODULE__{key: "custom"}), do: nil
  def refresh(%__MODULE__{}), do: 60

  @doc "The query params that reproduce a period."
  @spec to_params(t()) :: map()
  def to_params(%__MODULE__{key: "custom"} = p),
    do: %{"from" => DateTime.to_unix(p.from), "to" => DateTime.to_unix(p.to)}

  def to_params(%__MODULE__{key: key}), do: %{"period" => key}

  @doc "The period of the same length just before this one."
  @spec previous(t()) :: t()
  def previous(%__MODULE__{from: from, to: to}) do
    span = DateTime.diff(to, from)
    %__MODULE__{from: DateTime.add(from, -span), to: from, key: "custom"}
  end
end
