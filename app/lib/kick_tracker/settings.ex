defmodule KickTracker.Settings do
  @moduledoc """
  Admin settings (project.md §13.8), in the `settings` table: feature
  flags, the public groups, and the assumptions behind estimates. Every
  setting has a default, so an empty table is a working configuration.
  """

  alias KickTracker.Repo

  @defaults %{
    # Show the support page (subs, gifts, Kicks, estimated revenue) publicly.
    "support_page_public" => true,
    # Show top chatters and supporters by name on stream pages.
    "top_people_public" => true,
    # Assumptions behind the revenue estimate, always labeled as such.
    "sub_price_usd" => 4.99,
    "sub_share" => 0.95,
    "kick_value_usd" => 0.01
  }

  @doc "Every setting with its default."
  def defaults, do: @defaults

  @doc "One setting (cached briefly)."
  @spec get(String.t()) :: term()
  def get(key) when is_map_key(@defaults, key), do: Map.fetch!(all(), key)

  @doc "Every setting, stored values over defaults."
  @spec all() :: map()
  def all do
    KickTracker.Cache.fetch({:settings}, 30, fn ->
      stored =
        Repo.query!("SELECT key, value FROM settings").rows
        |> Map.new(fn [k, %{"v" => v}] -> {k, v} end)

      Map.merge(@defaults, Map.take(stored, Map.keys(@defaults)))
    end)
  end

  @doc "Stores a setting, cast to its default's type."
  @spec put(String.t(), term()) :: {:ok, term()} | {:error, String.t()}
  def put(key, value) when is_map_key(@defaults, key) do
    with {:ok, v} <- cast(@defaults[key], value) do
      Repo.query!(
        """
        INSERT INTO settings (key, value, inserted_at, updated_at) VALUES ($1, $2, now(), now())
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
        """,
        [key, %{"v" => v}]
      )

      KickTracker.Cache.clear()
      {:ok, v}
    end
  end

  defp cast(default, v) when is_boolean(default), do: {:ok, v in [true, "true", "on", "1"]}

  defp cast(default, v) when is_float(default) do
    case Float.parse(to_string(v)) do
      {f, ""} when f >= 0 -> {:ok, f}
      _ -> {:error, "must be a number"}
    end
  end
end
