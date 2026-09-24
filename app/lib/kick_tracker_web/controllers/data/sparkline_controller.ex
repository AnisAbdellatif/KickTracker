defmodule KickTrackerWeb.Data.SparklineController do
  @moduledoc """
  A live channel's sparkline for the home page (`/data/v1/sparklines/:slug`,
  project.md §13.5): its viewers over the last three hours in 5-minute
  buckets, `{"values": [...]}`, `null` where there was no reading.

  The home page adds `at=<minute>` so the URL moves with each minute's
  broadcast and caches see a new one; the answer itself is shared by
  every visitor for that minute. Public channels only.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{Cache, Reports}
  alias KickTrackerWeb.Data.JSON

  def show(conn, %{"slug" => slug}) do
    case Reports.channel_by_slug(slug) do
      nil ->
        JSON.not_found(conn)

      channel ->
        minute = div(System.system_time(:second), 60)

        values =
          Cache.fetch({:sparkline, channel.id, minute}, 60, fn ->
            Map.fetch!(Reports.sparklines([channel.id]), channel.id)
          end)

        JSON.send(conn, %{values: values}, DateTime.utc_now())
    end
  end
end
