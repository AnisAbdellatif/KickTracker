defmodule KickTrackerWeb.Data.StreamController do
  @moduledoc """
  One stream's chart data (`/data/v1/streams/:id`, project.md §13.3):
  viewers at 60s resolution with category bands, title ticks, markers and
  "no data" shading; chat per minute; support per minute. Active chatters
  in a rolling window come separately (`/chatters?window=5`), since the
  window is picked on the page. Only streams of public channels answer;
  support is left empty while the support page isn't public.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Channels, Reports, Series, Settings}
  alias KickTrackerWeb.Data.JSON

  def show(conn, %{"id" => id}) do
    case public_stream(id) do
      {:ok, stream, channel} -> send_stream(conn, stream, channel)
      :error -> JSON.not_found(conn)
    end
  end

  defp send_stream(conn, stream, channel) do
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
      # The stream's own readings (and its merged parts'), even when
      # it is excluded from the channel's figures.
      viewers: Series.viewers(channel, from, until, :raw, stream_ids: stream.stream_ids),
      chat: Series.chat(channel, from, until, :raw),
      support: support(channel, from, until),
      segments: timeline.segments,
      titles: timeline.titles,
      markers: Reports.markers(stream),
      annotations: KickTracker.Annotations.public_for(channel.id, from, until)
    }

    JSON.send(conn, data, until)
  end

  def chatters(conn, %{"id" => id} = params) do
    window =
      case Integer.parse(params["window"] || "5") do
        {w, ""} when w in [1, 5, 10, 15, 30] -> w
        _ -> 5
      end

    case public_stream(id) do
      {:ok, stream, _channel} ->
        JSON.send(
          conn,
          Series.active_chatters(stream, window),
          stream.ended_at || DateTime.utc_now()
        )

      :error ->
        JSON.not_found(conn)
    end
  end

  # A stream of a public channel, or :error (a hidden channel's streams
  # don't exist for the public site).
  defp public_stream(id) do
    with {id, ""} <- Integer.parse(id),
         %{} = stream <- Reports.stream(id),
         %{public: true} = channel <- Channels.get!(stream.channel_id) do
      {:ok, stream, channel}
    else
      _ -> :error
    end
  end

  defp support(channel, from, until) do
    if Settings.get("support_page_public"),
      do: Series.support(channel, from, until, :raw),
      else: %{res: "raw", tz: channel.timezone, t: [], subs: [], gifts: [], kicks: [], gaps: []}
  end
end
