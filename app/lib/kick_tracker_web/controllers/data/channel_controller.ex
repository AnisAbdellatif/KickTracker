defmodule KickTrackerWeb.Data.ChannelController do
  @moduledoc """
  A channel's history as JSON (`/data/v1/channels/:slug/...`, project.md
  §13.5). The range comes from `period`, or `from` and `to`; the server
  picks the resolution (§13.4), `res` can only ask for fewer points.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Reports, Series}
  alias KickTracker.Series.Resolution
  alias KickTrackerWeb.Data.JSON
  alias KickTrackerWeb.Period

  def show(conn, %{"slug" => slug, "series" => series} = params) do
    with %{} = channel <- Reports.channel_by_slug(slug),
         {:ok, data} <-
           series(series, channel, Period.parse(params, since: channel.tracked_since), params) do
      JSON.send(conn, data, Period.parse(params, since: channel.tracked_since).to)
    else
      _ -> JSON.not_found(conn)
    end
  end

  defp series("viewers", c, p, params),
    do: {:ok, Series.viewers(c, p.from, p.to, Resolution.parse(params["res"]))}

  defp series("chat", c, p, params),
    do: {:ok, Series.chat(c, p.from, p.to, Resolution.parse(params["res"]))}

  defp series("support", c, p, params),
    do: {:ok, Series.support(c, p.from, p.to, Resolution.parse(params["res"]))}

  defp series("followers", c, p, _), do: {:ok, Series.followers(c, p.from, p.to)}

  defp series("heatmap", c, p, _),
    do:
      {:ok,
       %{
         timezone: c.timezone,
         days: ~w(Mon Tue Wed Thu Fri Sat Sun),
         values: Reports.heatmap(c, p.from, p.to)
       }}

  defp series("categories", c, p, _) do
    rows = Reports.categories(c, p.from, p.to)
    {:ok, %{labels: Enum.map(rows, & &1.name), values: Enum.map(rows, &round2(&1.hours_watched))}}
  end

  defp series(_, _, _, _), do: :error

  defp round2(nil), do: nil
  defp round2(f), do: Float.round(f * 1.0, 2)
end
