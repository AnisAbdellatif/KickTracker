defmodule KickTrackerWeb.Admin.AnomaliesController do
  @moduledoc """
  One stream's chart for the anomalies page (project.md §19.4), admin
  only: the stream chart's data (as `/data/v1/streams/:id` gives it, for a
  hidden channel's streams too) with the findings as shaded annotations.
  Never cached: it names findings that aren't public.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Anomalies, Channels, Reports, Series}
  alias KickTrackerWeb.Admin.AnomaliesLive

  plug :require_admin

  def chart(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %{} = stream <- Reports.stream(id),
         channel = Channels.get!(stream.channel_id),
         %{} = result <- Anomalies.stream(channel, id) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(chart_data(channel, stream, result.findings))
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp require_admin(conn, _opts) do
    if conn.assigns[:current_admin],
      do: conn,
      else: conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"}) |> halt()
  end

  defp chart_data(channel, stream, findings) do
    to = stream.ended_at || DateTime.utc_now()
    # A minute either side, so the first and last samples show.
    from = DateTime.add(stream.started_at, -60)
    until = DateTime.add(to, 60)
    timeline = Reports.timeline(stream)

    %{
      stream: %{
        id: stream.id,
        started_at: DateTime.to_unix(stream.started_at),
        ended_at: stream.ended_at && DateTime.to_unix(stream.ended_at),
        live: is_nil(stream.ended_at)
      },
      viewers: Series.viewers(channel, from, until, :raw, stream_ids: stream.stream_ids),
      chat: Series.chat(channel, from, until, :raw),
      support: %{t: [], subs: [], gifts: [], kicks: [], gaps: []},
      segments: timeline.segments,
      titles: timeline.titles,
      markers: Reports.markers(stream),
      annotations:
        for f <- findings do
          %{
            from: DateTime.to_unix(f.from),
            to: DateTime.to_unix(f.to),
            text: AnomaliesLive.label(f.kind)
          }
        end
    }
  end
end
