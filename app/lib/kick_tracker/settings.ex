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

  # What a number setting may be: a share is a fraction; prices are
  # capped well above anything real, to catch a slipped digit.
  @ranges %{
    "sub_price_usd" => {0, 1000},
    "sub_share" => {0, 1},
    "kick_value_usd" => {0, 100}
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

  @doc "The range a number setting must fall in, inclusive."
  @spec range(String.t()) :: {number(), number()} | nil
  def range(key), do: Map.get(@ranges, key)

  @doc "Stores a setting, cast to its default's type and checked against its range."
  @spec put(String.t(), term()) :: {:ok, term()} | {:error, String.t()}
  def put(key, value) when is_map_key(@defaults, key) do
    with {:ok, v} <- cast(key, @defaults[key], value) do
      Repo.transaction(fn -> store(key, v) end)
      KickTracker.Cache.clear()
      {:ok, v}
    end
  end

  @doc """
  Stores several settings at once: every value is cast and checked first,
  and either all are stored, with one audit entry for the change, or none
  is (the first error is returned, with its key). Keys that aren't
  settings are ignored.
  """
  @spec put_all(map(), KickTracker.Admins.Admin.t() | nil) ::
          {:ok, map()} | {:error, String.t(), String.t()}
  def put_all(values, admin) when is_map(values) do
    cast =
      for {key, value} <- values, is_map_key(@defaults, key) do
        {key, cast(key, @defaults[key], value)}
      end

    case Enum.find(cast, &match?({_, {:error, _}}, &1)) do
      {key, {:error, msg}} ->
        {:error, key, msg}

      nil ->
        values = Map.new(cast, fn {k, {:ok, v}} -> {k, v} end)

        {:ok, _} =
          Repo.transaction(fn ->
            Enum.each(values, fn {k, v} -> store(k, v) end)
            KickTracker.Audit.log(admin, "settings.update", nil, values)
          end)

        KickTracker.Cache.clear()
        {:ok, values}
    end
  end

  defp store(key, v) do
    Repo.query!(
      """
      INSERT INTO settings (key, value, inserted_at, updated_at) VALUES ($1, $2, now(), now())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
      """,
      [key, %{"v" => v}]
    )
  end

  defp cast(_key, default, v) when is_boolean(default),
    do: {:ok, v in [true, "true", "on", "1"]}

  defp cast(key, default, v) when is_float(default) do
    {min, max} = @ranges[key]

    parsed =
      cond do
        is_number(v) -> {v / 1, ""}
        is_binary(v) -> v |> String.trim() |> Float.parse()
        true -> :error
      end

    case parsed do
      {f, ""} when f >= min and f <= max -> {:ok, f}
      {f, ""} when is_float(f) -> {:error, "must be between #{min} and #{max}"}
      _ -> {:error, "must be a number"}
    end
  end
end
