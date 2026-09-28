defmodule KickTrackerWeb.Api.V1.ChannelController do
  @moduledoc """
  Channels in the public read API (project.md §13.10): the channels a key
  reaches, what is live now, a channel's streams and its series over a
  range. A channel the key doesn't reach is a 404, like one that doesn't
  exist.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{ApiKeys, Channels, Reports, Series}
  alias KickTracker.ApiKeys.Access
  alias KickTracker.Series.Resolution
  alias KickTrackerWeb.Api.V1.JSON
  alias KickTrackerWeb.Period

  # A stream row's figures, by the scope that reads them.
  @stream_figures [
    {"viewers", [:avg_viewers, :peak_viewers, :hours_watched]},
    {"chat", [:unique_chatters, :messages]},
    {"followers", [:follower_gain, :follows]},
    {"support", [:subs, :resubs, :gifted_subs, :kicks]}
  ]

  @series ~w(viewers chat followers support heatmap categories)

  def index(conn, _params) do
    key = conn.assigns.api_key
    open = Channels.open_streams()

    channels =
      for {c, access} <- ApiKeys.channels(key),
          Access.listed?(key, access),
          do: channel_json(key, c, access, open)

    JSON.send(conn, %{channels: channels}, DateTime.utc_now())
  end

  def show(conn, %{"slug" => slug}) do
    key = conn.assigns.api_key

    case ApiKeys.channel(key, slug) do
      {:ok, c, access} ->
        JSON.send(conn, channel_json(key, c, access, Channels.open_streams()), DateTime.utc_now())

      :error ->
        JSON.not_found(conn)
    end
  end

  defp channel_json(key, c, access, open) do
    base = %{
      slug: c.slug,
      live: Map.has_key?(open, c.id),
      access: Atom.to_string(access),
      scopes: Enum.filter(all_scopes(), &Access.can?(key, access, &1))
    }

    full =
      if access == :full,
        do: %{
          kick_user_id: c.kick_user_id,
          timezone: c.timezone,
          tracked_since: JSON.time(c.tracked_since),
          tracking: c.active
        },
        else: %{}

    admin = if key.admin, do: %{visibility: Atom.to_string(c.visibility)}, else: %{}
    base |> Map.merge(full) |> Map.merge(admin)
  end

  defp all_scopes, do: Access.scopes() ++ ["chat_log"]

  ## Now

  def live(conn, _params) do
    key = conn.assigns.api_key
    reached = Map.new(ApiKeys.channels(key), fn {c, access} -> {c.id, access} end)

    channels =
      Reports.live_now(visibility: :any, full: true)
      |> Enum.map(&{&1, Map.get(reached, &1.channel_id, :none)})
      |> Enum.filter(fn {_, access} -> Access.can?(key, access, "live") end)
      |> Enum.map(fn {l, access} -> now_json(l.slug, l, access, l.channel_id) end)

    JSON.send(conn, %{channels: channels}, DateTime.utc_now())
  end

  def now(conn, %{"slug" => slug}) do
    key = conn.assigns.api_key

    with {:ok, c, access} <- ApiKeys.channel(key, slug),
         {:scope, true} <- {:scope, Access.can?(key, access, "live")} do
      live =
        Enum.find(Reports.live_now(visibility: :any, full: true), &(&1.channel_id == c.id))

      JSON.send(conn, now_json(c.slug, live, access, c.id), DateTime.utc_now())
    else
      :error -> JSON.not_found(conn)
      {:scope, false} -> JSON.out_of_scope(conn, "live")
    end
  end

  defp now_json(slug, nil, _access, _id), do: %{slug: slug, live: false}

  defp now_json(slug, live, access, channel_id) do
    now = %{
      slug: slug,
      live: true,
      viewers: live.viewers,
      observed_at: JSON.time(live.observed_at),
      active_chatters: Series.chatters_now(channel_id)
    }

    if access == :full,
      do:
        Map.merge(now, %{
          stream_id: live.stream_id,
          started_at: JSON.time(live.started_at),
          title: live.title,
          category: live.category
        }),
      else: now
  end

  ## History

  def streams(conn, %{"slug" => slug} = params) do
    key = conn.assigns.api_key

    with {:ok, c, access} <- ApiKeys.channel(key, slug),
         {:scope, true} <- {:scope, Access.can?(key, access, "channels")} do
      {from, to, clamped} = range(key, c, params)

      rows =
        Reports.streams(c, from: from, to: to, limit: limit(params["limit"]))
        |> Enum.map(&stream_json(key, access, &1))

      JSON.send(conn, Map.merge(range_json(from, to, clamped), %{streams: rows}), to)
    else
      :error -> JSON.not_found(conn)
      {:scope, false} -> JSON.out_of_scope(conn, "channels")
    end
  end

  defp limit(param) do
    case Integer.parse(param || "") do
      {n, ""} when n in 1..500 -> n
      _ -> 100
    end
  end

  defp stream_json(key, access, s) do
    figures =
      for {scope, fields} <- @stream_figures,
          Access.can?(key, access, scope),
          field <- fields,
          into: %{},
          do: {field, Map.get(s, field)}

    Map.merge(
      %{
        id: s.id,
        started_at: JSON.time(s.started_at),
        ended_at: JSON.time(s.ended_at),
        airtime_s: s.airtime_s,
        category: s.category,
        excluded: s.excluded?
      },
      figures
    )
  end

  def series(conn, %{"slug" => slug, "series" => series} = params) when series in @series do
    key = conn.assigns.api_key
    scope = if series == "heatmap", do: "viewers", else: series

    with {:ok, c, access} <- ApiKeys.channel(key, slug),
         {:scope, true} <- {:scope, Access.can?(key, access, scope)} do
      {from, to, clamped} = range(key, c, params)
      res = Access.resolution(key, Resolution.parse(params["res"]))

      data =
        series
        |> series_json(c, from, to, res)
        |> Map.merge(range_json(from, to, clamped))

      JSON.send(conn, data, to)
    else
      :error -> JSON.not_found(conn)
      {:scope, false} -> JSON.out_of_scope(conn, scope)
    end
  end

  def series(conn, _params), do: JSON.not_found(conn)

  defp series_json("viewers", c, from, to, res), do: Series.viewers(c, from, to, res)
  defp series_json("chat", c, from, to, res), do: Series.chat(c, from, to, res)
  defp series_json("followers", c, from, to, res), do: Series.followers(c, from, to, res)
  defp series_json("support", c, from, to, res), do: Series.support(c, from, to, res)

  defp series_json("heatmap", c, from, to, _res),
    do: %{
      timezone: c.timezone,
      days: ~w(Mon Tue Wed Thu Fri Sat Sun),
      values: Reports.heatmap(c, from, to)
    }

  defp series_json("categories", c, from, to, _res),
    do: %{categories: Enum.map(Reports.categories(c, from, to), &Map.delete(&1, :category_id))}

  # The range asked for (`period`, or `from` and `to`), as far back as the key reads.
  defp range(key, channel, params) do
    period = Period.parse(params, since: channel.tracked_since)
    Access.clamp(key, period.from, period.to, DateTime.utc_now())
  end

  defp range_json(from, to, clamped),
    do: %{from: DateTime.to_unix(from), to: DateTime.to_unix(to), clamped: clamped}
end
