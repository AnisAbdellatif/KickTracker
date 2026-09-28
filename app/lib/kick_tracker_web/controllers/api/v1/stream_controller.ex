defmodule KickTrackerWeb.Api.V1.StreamController do
  @moduledoc """
  One stream in the public read API (project.md §13.10): its timeline,
  and the series the key's scopes include; active chatters in a rolling
  window apart. Only streams of channels the key reaches fully.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Annotations, ApiKeys, Channels, Reports, Series}
  alias KickTracker.ApiKeys.Access
  alias KickTrackerWeb.Api.V1.JSON

  @support_markers ~w(gift kicks)

  def show(conn, %{"id" => id}) do
    key = conn.assigns.api_key

    with {:ok, stream, channel} <- fetch(key, id),
         {:scope, true} <- {:scope, Access.can?(key, :full, "channels")} do
      now = DateTime.utc_now()
      to = stream.ended_at || now
      # A minute either side, so the first and last readings show.
      {from, until, clamped} =
        Access.clamp(key, DateTime.add(stream.started_at, -60), DateTime.add(to, 60), now)

      res = Access.resolution(key, :raw)
      timeline = Reports.timeline(stream)
      can? = &Access.can?(key, :full, &1)

      markers =
        Enum.filter(
          Reports.markers(stream),
          &(&1.kind not in @support_markers or can?.("support"))
        )

      data =
        %{
          stream: %{
            id: stream.id,
            channel: channel.slug,
            started_at: JSON.time(stream.started_at),
            ended_at: JSON.time(stream.ended_at),
            live: is_nil(stream.ended_at)
          },
          from: DateTime.to_unix(from),
          to: DateTime.to_unix(until),
          clamped: clamped,
          segments: timeline.segments,
          titles: timeline.titles,
          markers: markers,
          annotations: Annotations.public_for(channel.id, from, until)
        }
        |> put_if(can?.("viewers"), :viewers, fn ->
          Series.viewers(channel, from, until, res, stream_ids: stream.stream_ids)
        end)
        |> put_if(can?.("chat"), :chat, fn -> Series.chat(channel, from, until, res) end)
        |> put_if(can?.("support"), :support, fn -> Series.support(channel, from, until, res) end)

      JSON.send(conn, data, until)
    else
      :error -> JSON.not_found(conn)
      {:scope, false} -> JSON.out_of_scope(conn, "channels")
    end
  end

  defp put_if(data, true, field, fun), do: Map.put(data, field, fun.())
  defp put_if(data, false, _field, _fun), do: data

  # Per-minute counts: not for a key held to a coarser resolution; minutes
  # before the key's history are left out.
  def chatters(conn, %{"id" => id} = params) do
    key = conn.assigns.api_key

    window =
      case Integer.parse(params["window"] || "5") do
        {w, ""} when w in [1, 5, 10, 15, 30] -> w
        _ -> 5
      end

    with {:ok, stream, _channel} <- fetch(key, id),
         {:scope, true} <- {:scope, Access.can?(key, :full, "chat")},
         {:res, true} <- {:res, key.min_res in [nil, "raw"]} do
      now = DateTime.utc_now()
      to = stream.ended_at || now
      {from, _, clamped} = Access.clamp(key, stream.started_at, to, now)
      data = Series.active_chatters(stream, window)
      since = DateTime.to_unix(from)

      kept =
        data.t |> Enum.zip(data.chatters) |> Enum.filter(fn {t, _} -> t >= since end)

      JSON.send(
        conn,
        %{
          window: window,
          clamped: clamped,
          t: Enum.map(kept, &elem(&1, 0)),
          chatters: Enum.map(kept, &elem(&1, 1))
        },
        to
      )
    else
      :error ->
        JSON.not_found(conn)

      {:scope, false} ->
        JSON.out_of_scope(conn, "chat")

      {:res, false} ->
        JSON.error(conn, 403, "resolution", "This key can't read per-minute figures.")
    end
  end

  # A stream of a channel the key reaches fully.
  defp fetch(key, id) do
    with {id, ""} <- Integer.parse(id),
         %{} = stream <- Reports.stream(id),
         channel = Channels.get!(stream.channel_id),
         :full <- ApiKeys.access(key, channel) do
      {:ok, stream, channel}
    else
      _ -> :error
    end
  end
end
