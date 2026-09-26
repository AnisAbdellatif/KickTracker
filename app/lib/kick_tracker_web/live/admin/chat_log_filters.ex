defmodule KickTrackerWeb.Admin.ChatLogFilters do
  @moduledoc """
  The chat log's filters (project.md §12.8), from the query string, so a
  view or an export is reproducible from its URL (the admin page and the
  CSV export read the same parameters):

    * `channels` — channel ids, comma-separated;
    * `users` — usernames or Kick user ids, comma- or space-separated;
    * `from`, `to` — UTC, `YYYY-MM-DDTHH:MM` (`[from, to)`);
    * `period` — `1h`, `24h`, `7d` or `30d` back from now, instead of
      `from` and `to`.
  """

  alias KickTracker.ChatLog

  @periods %{"1h" => 3600, "24h" => 86_400, "7d" => 7 * 86_400, "30d" => 30 * 86_400}

  @doc "The preset periods, shortest first."
  def periods, do: ~w(1h 24h 7d 30d)

  @doc """
  The filters for `ChatLog.messages/1` and the form's values. Users that
  match nobody leave the filter empty rather than dropped, so an unknown
  name shows nothing instead of everyone.
  """
  @spec parse(map()) :: {map(), map()}
  def parse(params) do
    form = Map.new(~w(channels users from to period), &{&1, String.trim(params[&1] || "")})

    {from, to, form} =
      case @periods[form["period"]] do
        nil ->
          {time(form["from"]), time(form["to"]), %{form | "period" => ""}}

        seconds ->
          {DateTime.add(DateTime.utc_now(), -seconds), nil, %{form | "from" => "", "to" => ""}}
      end

    filters =
      %{}
      |> put(:channel_ids, ids(form["channels"]))
      |> put(:user_ids, users(form["users"]))
      |> put(:from, from)
      |> put(:to, to)

    {filters, form}
  end

  @doc "The items of a comma-separated value (channel ids, users)."
  @spec items(String.t() | nil) :: [String.t()]
  def items(nil), do: []
  def items(text), do: String.split(text, ~r/[\s,]+/, trim: true)

  @doc "The value with `item` added, or removed if it was there."
  @spec toggle(String.t() | nil, String.t()) :: String.t()
  def toggle(text, item) do
    list = items(text)
    if item in list, do: Enum.join(list -- [item], ","), else: Enum.join(list ++ [item], ",")
  end

  @doc "The query string for these form values (empty ones left out)."
  @spec query(map()) :: map()
  def query(form), do: Map.reject(form, fn {_k, v} -> v in [nil, ""] end)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp ids(""), do: nil

  defp ids(text) do
    text
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.flat_map(fn s ->
      case Integer.parse(s) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
  end

  defp users(""), do: nil

  defp users(text),
    do: text |> String.split(~r/[\s,]+/, trim: true) |> Enum.flat_map(&ChatLog.find_users/1)

  @doc "A UTC time typed as `YYYY-MM-DDTHH:MM` (or with seconds); nil otherwise."
  @spec time(String.t()) :: DateTime.t() | nil
  def time(""), do: nil

  def time(text) do
    text = if String.length(text) == 16, do: text <> ":00", else: text

    case NaiveDateTime.from_iso8601(text) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end
end
