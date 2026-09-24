defmodule KickTrackerWeb.Period do
  @moduledoc """
  The period a page or a data request covers, from the query string, so
  every view is reproducible from its URL (project.md §13.2):

    * `period=24h|7d|30d|90d|1y|all` (default `30d`), ending now;
    * or `from` and `to`, as unix seconds or ISO 8601 (a custom range).
  """

  @presets %{
    "24h" => 86_400,
    "7d" => 7 * 86_400,
    "30d" => 30 * 86_400,
    "90d" => 90 * 86_400,
    "1y" => 365 * 86_400
  }
  @max_span 20 * 365 * 86_400

  defstruct [:from, :to, :key]

  @type t :: %__MODULE__{from: DateTime.t(), to: DateTime.t(), key: String.t()}

  @doc "The period presets offered by the period picker, in order."
  def presets, do: ~w(24h 7d 30d 90d 1y all)

  @doc """
  Parses the query params. `since` is where "all" starts (the channel's
  tracking start, or the first stream). Unparseable input falls back to
  the default rather than failing.
  """
  @spec parse(map(), keyword()) :: t()
  def parse(params, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)
    default = Keyword.get(opts, :default, "30d")

    with {:ok, from} <- time(params["from"]),
         {:ok, to} <- time(params["to"]),
         true <- DateTime.compare(from, to) == :lt,
         true <- DateTime.diff(to, from) <= @max_span do
      %__MODULE__{from: from, to: to, key: "custom"}
    else
      _ -> preset(params["period"] || default, now, opts[:since], default)
    end
  end

  defp preset("all", now, since, _default) do
    from = (since && DateTime.truncate(since, :second)) || DateTime.add(now, -365, :day)
    from = if DateTime.compare(from, now) == :lt, do: from, else: DateTime.add(now, -1, :day)
    %__MODULE__{from: from, to: now, key: "all"}
  end

  defp preset(key, now, since, default) do
    case @presets[key] do
      nil -> preset(default, now, since, default)
      span -> %__MODULE__{from: DateTime.add(now, -span), to: now, key: key}
    end
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
