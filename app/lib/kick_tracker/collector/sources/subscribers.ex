defmodule KickTracker.Collector.Sources.Subscribers do
  @moduledoc """
  Every 5 minutes, `GET /channels` for every tracked channel, 50 per
  request (project.md §3): subscriber totals (active, gifted, cancelled)
  and the slug Kick reports now, so a rename is followed. Coverage source
  `subscribers`. A total missing from the answer is no reading, never a
  zero.
  """

  @behaviour KickTracker.Collector.Source

  alias KickTracker.Kick.API

  @batch 50

  @impl true
  def name, do: :subscribers

  @impl true
  def coverage, do: {"subscribers", 660}

  @impl true
  def init(opts), do: %{interval_ms: Keyword.get(opts, :interval_ms, 300_000)}

  @impl true
  def interval_ms(state), do: state.interval_ms

  @impl true
  def limits(_state), do: %{concurrency: 2, timeout_ms: 40_000}

  @impl true
  def units(channels, state, _now),
    do: {Enum.map(Enum.chunk_every(channels, @batch), &%{channels: &1}), state}

  @impl true
  def fetch(%{channels: channels}),
    do: API.channels(Enum.map(channels, & &1.kick_user_id))

  @impl true
  def record(%{channels: channels}, {:ok, found}, at, state) do
    by_user = Map.new(found, &{&1["broadcaster_user_id"], &1})
    pairs = for c <- channels, data = by_user[c.kick_user_id], data != nil, do: {c, data}

    samples = for {c, data} <- pairs, row = sample(c, data, at), row != nil, do: row

    renames =
      for {c, %{"slug" => slug}} <- pairs,
          is_binary(slug),
          slug != "",
          slug != c.slug,
          do: {c, slug}

    ops =
      if(samples == [], do: [], else: [{:subscriber_samples, samples}]) ++
        for({c, slug} <- renames, do: {:slug, c.id, slug, at})

    {ops, for({c, slug} <- renames, do: {:channel, c.id, %{slug: slug}}), state}
  end

  def record(_unit, {:error, _}, _at, state), do: {[], [], state}

  # Only the channels whose totals were in the answer: one missing from it
  # (banned, or Kick simply left it out) got no reading, a gap.
  @impl true
  def covered(%{channels: channels}, {:ok, found}) do
    by_user = Map.new(found, &{&1["broadcaster_user_id"], &1})
    for c <- channels, data = by_user[c.kick_user_id], sample(c, data, nil) != nil, do: c.id
  end

  defp sample(c, data, at) do
    case {data["active_subscribers_count"], data["active_gifted_subscribers_count"],
          data["canceled_subscribers_count"]} do
      {a, g, x} when is_integer(a) and is_integer(g) and is_integer(x) ->
        %{channel_id: c.id, observed_at: at, active: a, active_gifted: g, canceled: x}

      _ ->
        nil
    end
  end
end
