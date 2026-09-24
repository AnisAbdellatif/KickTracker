defmodule Sim.Scenario.Channel do
  @moduledoc """
  One simulated channel: who it is, how big, when it streams, how busy its
  chat is. Pure.

  Only `slug` is required; everything else has a default, so a scenario can
  be as short as `[slug: "somestreamer"]`. Ids and the per-channel seed are
  derived from the slug, so they're stable across runs and unique per
  channel without being written down.
  """

  defstruct [
    :slug,
    :username,
    :user_id,
    :channel_id,
    :chatroom_id,
    :seed,
    :language,
    :verified,
    :peak_viewers,
    :schedule,
    :categories,
    :titles,
    :chat,
    :followers,
    :subscribers
  ]

  @type schedule ::
          :always
          | :never
          | %{days: [1..7], start_hour: 0..23, start_minute: 0..59, duration_min: pos_integer()}

  @type t :: %__MODULE__{}

  @default_categories [
    %{id: 15, name: "Just Chatting", slug: "just-chatting"},
    %{id: 14_353, name: "EA Sports FC 27", slug: "ea-sports-fc-27"}
  ]

  @doc "Builds a channel from a keyword list or map; `:slug` is required."
  @spec new(keyword() | map(), integer()) :: t()
  def new(spec, fallback_seed \\ 1)
  def new(spec, fallback_seed) when is_list(spec), do: spec |> Map.new() |> new(fallback_seed)

  def new(%{} = spec, fallback_seed) do
    slug = require_slug(spec)
    known = __struct__() |> Map.from_struct() |> Map.keys() |> MapSet.new()

    case spec |> Map.keys() |> Enum.reject(&(&1 in known)) do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown channel options: #{inspect(unknown)}"
    end

    hash = :erlang.phash2(slug, 1_000_000)

    %__MODULE__{
      slug: slug,
      username: Map.get(spec, :username, slug),
      user_id: Map.get(spec, :user_id, 1_000_000 + hash),
      channel_id: Map.get(spec, :channel_id, 2_000_000 + hash),
      chatroom_id: Map.get(spec, :chatroom_id, 3_000_000 + hash),
      seed: Map.get(spec, :seed, hash + fallback_seed),
      language: Map.get(spec, :language, "en"),
      verified: Map.get(spec, :verified, false),
      peak_viewers: Map.get(spec, :peak_viewers, 500),
      schedule: schedule(Map.get(spec, :schedule, :always)),
      categories: categories(Map.get(spec, :categories, @default_categories)),
      titles: Map.get(spec, :titles, ["Stream time", "Late night stream", "Back at it"]),
      chat: chat(Map.get(spec, :chat, %{})),
      followers: Map.get(spec, :followers, followers(spec, hash)),
      subscribers: subscribers(Map.get(spec, :subscribers, %{}))
    }
  end

  defp require_slug(%{slug: slug}) when is_binary(slug) and slug != "", do: slug

  defp require_slug(spec),
    do: raise(ArgumentError, "a channel needs a :slug, got: #{inspect(spec)}")

  defp schedule(:always), do: :always
  defp schedule(:never), do: :never

  defp schedule(%{} = s) do
    %{
      days: Map.get(s, :days, [1, 2, 3, 4, 5, 6, 7]),
      start_hour: Map.get(s, :start_hour, 20),
      start_minute: Map.get(s, :start_minute, 0),
      duration_min: Map.get(s, :duration_min, 240)
    }
    |> validate_schedule()
  end

  defp schedule(other), do: raise(ArgumentError, "bad schedule: #{inspect(other)}")

  defp validate_schedule(%{days: days, start_hour: h, start_minute: m, duration_min: d} = s) do
    cond do
      days == [] or Enum.any?(days, &(&1 not in 1..7)) ->
        raise ArgumentError, "schedule days must be a non-empty list of 1..7 (Monday..Sunday)"

      h not in 0..23 or m not in 0..59 ->
        raise ArgumentError, "schedule start must be a valid hour and minute"

      not (is_integer(d) and d > 0 and d <= 7 * 24 * 60) ->
        raise ArgumentError, "schedule duration_min must be between 1 and a week"

      true ->
        s
    end
  end

  defp categories([]), do: raise(ArgumentError, "a channel needs at least one category")

  defp categories(categories) do
    Enum.map(categories, fn c ->
      c = Map.new(c)

      %{
        id: Map.fetch!(c, :id),
        name: Map.fetch!(c, :name),
        slug: Map.get(c, :slug, slugify(c.name))
      }
    end)
  end

  defp chat(%{} = c) do
    %{
      # Messages per viewer per minute: a 500-viewer stream at 0.05 sends
      # about 25 messages a minute, which matches what the recordings show.
      messages_per_viewer_per_min: Map.get(c, :messages_per_viewer_per_min, 0.05),
      # How many different people those messages come from.
      messages_per_chatter: Map.get(c, :messages_per_chatter, 2.5),
      # Chatters are drawn from a pool this many times the peak audience, so
      # the same people come back within a stream and across streams.
      pool_factor: Map.get(c, :pool_factor, 3)
    }
  end

  # Roughly 40 followers per peak viewer, the ratio the recordings showed,
  # plus some variation so no two channels match exactly.
  defp followers(spec, hash) do
    peak = Map.get(spec, :peak_viewers, 500)
    peak * 40 + rem(hash, max(peak * 4, 1))
  end

  defp subscribers(%{} = s) do
    %{
      active: Map.get(s, :active, 0),
      gifted: Map.get(s, :gifted, 0),
      canceled: Map.get(s, :canceled, 0)
    }
  end

  defp slugify(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
end
