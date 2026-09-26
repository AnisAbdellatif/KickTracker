defmodule KickTrackerWeb.AvatarController do
  @moduledoc """
  A channel's picture, our copy of it (project.md §12.9), so a visitor's
  browser never contacts Kick. Asked for with its version (`?v=`, from
  `Avatars.versions/0`), it is cached for a year: a new picture has a new
  version. Hidden channels have none.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.Avatars

  # The type is one of four image types, recognised from the bytes when
  # they were copied (`Avatars.sniff/1`), never what a server claimed; the
  # answer carries nosniff and a sandboxing CSP.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  def show(conn, %{"id" => id} = params) do
    with {id, ""} <- Integer.parse(id),
         %{} = avatar <- Avatars.get(id) do
      etag = ~s("#{avatar.sha256}")

      cache =
        if params["v"] && String.starts_with?(avatar.sha256, params["v"]),
          do: "public, max-age=31536000, immutable",
          else: "public, max-age=3600"

      conn =
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("cache-control", cache)
        |> put_resp_header("x-content-type-options", "nosniff")
        # Served as an image, never as a page.
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")

      if etag in get_req_header(conn, "if-none-match"),
        do: send_resp(conn, 304, ""),
        else:
          conn |> put_resp_content_type(avatar.content_type, nil) |> send_resp(200, avatar.data)
    else
      _ -> conn |> put_resp_header("cache-control", "public, max-age=300") |> send_resp(404, "")
    end
  end
end
