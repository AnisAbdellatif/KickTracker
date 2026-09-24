defmodule KickTrackerWeb.Data.ChannelController do
  @moduledoc """
  A channel's history as JSON (`/data/v1/channels/:slug/...`, project.md
  §13.5). The range comes from `period`, or `from` and `to`; the server
  picks the resolution (§13.4), `res` can only ask for fewer points.
  Only public channels answer, and support only while the support page is
  public (the `support_page_public` setting).
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Reports, Series, Settings}
  alias KickTracker.Series.Resolution
  alias KickTrackerWeb.Data.JSON
  alias KickTrackerWeb.Period

  def show(conn, %{"slug" => slug, "series" => series} = params) do
    with %{} = channel <- Reports.channel_by_slug(slug),
         period = Period.parse(params, since: channel.tracked_since),
         {:ok, data} <- series(series, channel, period, params) do
      JSON.send(conn, data, period.to)
    else
      _ -> JSON.not_found(conn)
    end
  end

  defp series("viewers", c, p, params),
    do: {:ok, Series.viewers(c, p.from, p.to, Resolution.parse(params["res"])) |> tz_note(c, p)}

  defp series("chat", c, p, params),
    do: {:ok, Series.chat(c, p.from, p.to, Resolution.parse(params["res"])) |> tz_note(c, p)}

  defp series("support", c, p, params) do
    if Settings.get("support_page_public"),
      do:
        {:ok, Series.support(c, p.from, p.to, Resolution.parse(params["res"])) |> tz_note(c, p)},
      else: :error
  end

  defp series("followers", c, p, params),
    do: {:ok, Series.followers(c, p.from, p.to, Resolution.parse(params["res"]))}

  defp series("heatmap", c, p, _) do
    {:ok,
     %{
       timezone: c.timezone,
       days: ~w(Mon Tue Wed Thu Fri Sat Sun),
       values: Reports.heatmap(c, p.from, p.to),
       note: tz_note_text(c, p)
     }}
  end

  defp series("categories", c, p, _) do
    rows = Reports.categories(c, p.from, p.to)
    {:ok, %{labels: Enum.map(rows, & &1.name), values: Enum.map(rows, &round2(&1.hours_watched))}}
  end

  defp series(_, _, _, _), do: :error

  # Days and weekdays are built from UTC hours: in a timezone a whole
  # number of hours from UTC they are exact, otherwise (+05:30, +05:45,
  # -03:30) each local day and hour is off by the odd minutes, and the
  # response says so (project.md §12.2).
  defp tz_note(%{res: res} = data, c, p) when res in ["1d", "1w"] do
    case tz_note_text(c, p) do
      nil -> data
      note -> Map.put(data, :note, note)
    end
  end

  defp tz_note(data, _c, _p), do: data

  defp tz_note_text(c, p) do
    unless Series.whole_hour_offsets?(c.timezone, p.from, p.to),
      do:
        gettext(
          "Days and hours are counted in whole UTC hours: in this channel's time zone they can be off by up to 45 minutes."
        )
  end

  defp round2(nil), do: nil
  defp round2(f), do: Float.round(f * 1.0, 2)
end
