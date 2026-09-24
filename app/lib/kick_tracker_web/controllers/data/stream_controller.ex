defmodule KickTrackerWeb.Data.StreamController do
  @moduledoc """
  One stream's chart data (`/data/v1/streams/:id`, project.md §13.3):
  viewers at 60s resolution with category bands, title ticks, markers and
  "no data" shading; chat per minute; support per minute. Active chatters
  in a rolling window come separately (`/chatters?window=5`), since the
  window is picked on the page.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Channels, Reports, Series}
  alias KickTrackerWeb.Data.JSON

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %{} = stream <- Reports.stream(id),
         %{public: true} = channel <- Channels.get!(stream.channel_id) do
      to = stream.ended_at || DateTime.utc_now()
      # A minute either side, so the first and last samples show.
      from = DateTime.add(stream.started_at, -60)
      until = DateTime.add(to, 60)
      timeline = Reports.timeline(stream)

      data = %{
        stream: %{
          id: stream.id,
          started_at: DateTime.to_unix(stream.started_at),
          ended_at: stream.ended_at && DateTime.to_unix(stream.ended_at),
          live: is_nil(stream.ended_at)
        },
        viewers: Series.viewers(channel, from, until, :raw),
        chat: Series.chat(channel, from, until, :raw),
        support: Series.support(channel, from, until, :raw),
        segments: timeline.segments,
        titles: timeline.titles,
        markers: Reports.markers(stream),
        annotations: KickTracker.Annotations.public_for(channel.id, from, until)
      }

      JSON.send(conn, data, until)
    else
      _ -> JSON.not_found(conn)
    end
  end

  def chatters(conn, %{"id" => id} = params) do
    window =
      case Integer.parse(params["window"] || "5") do
        {w, ""} when w in [1, 5, 10, 15, 30] -> w
        _ -> 5
      end

    with {id, ""} <- Integer.parse(id),
         %{} = stream <- Reports.stream(id) do
      JSON.send(
        conn,
        Series.active_chatters(stream, window),
        stream.ended_at || DateTime.utc_now()
      )
    else
      _ -> JSON.not_found(conn)
    end
  end
end
