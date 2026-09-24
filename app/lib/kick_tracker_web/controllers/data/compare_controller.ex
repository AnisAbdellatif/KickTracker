defmodule KickTrackerWeb.Data.CompareController do
  @moduledoc """
  Several channels on one metric and period (`/data/v1/compare?c=a,b`,
  project.md §13.2): one column per channel on a shared time axis.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Reports, Series}
  alias KickTrackerWeb.Data.JSON
  alias KickTrackerWeb.Period

  @metrics ~w(viewers chat followers)

  def show(conn, params) do
    channels =
      (params["c"] || "")
      |> String.split(",", trim: true)
      |> Enum.take(4)
      |> Enum.map(&Reports.channel_by_slug/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    metric = if params["metric"] in @metrics, do: params["metric"], else: "viewers"
    period = Period.parse(params)

    series =
      for c <- channels do
        s =
          case metric do
            "viewers" -> Series.viewers(c, period.from, period.to)
            "chat" -> Series.chat(c, period.from, period.to)
            "followers" -> Series.followers(c, period.from, period.to)
          end

        %{name: c.slug, t: s.t, v: s[:avg] || s[:messages] || s[:v], gaps: s[:gaps] || []}
      end

    JSON.send(conn, %{metric: metric, series: series}, period.to)
  end
end
