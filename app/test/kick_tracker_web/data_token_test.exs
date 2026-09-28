defmodule KickTrackerWeb.DataTokenTest do
  @moduledoc """
  `/data/v1` answers our own pages only (project.md §13.5): a page token
  in `x-data-token`, and no request from another site's page.
  """

  use KickTrackerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import KickTracker.Fixtures

  alias KickTrackerWeb.DataToken

  setup do
    KickTracker.Cache.clear()
    channel!(slug: "somestreamer")
    :ok
  end

  @path "/data/v1/channels/somestreamer/viewers?period=7d"

  test "a request with the page's token is answered", %{conn: conn} do
    assert json_response(get(conn, @path), 200)["res"]
  end

  test "without a valid token, a 403 that says so", %{conn: conn} do
    bare = delete_req_header(conn, "x-data-token")
    assert json_response(get(bare, @path), 403) == %{"error" => "data_token"}

    forged = put_req_header(bare, "x-data-token", "SFMyNTY.not.ours")
    assert json_response(get(forged, @path), 403) == %{"error" => "data_token"}

    # Another endpoint's token (same key, other purpose) doesn't pass.
    other = Phoenix.Token.sign(KickTrackerWeb.Endpoint, "something else", :page)
    assert json_response(get(put_req_header(bare, "x-data-token", other), @path), 403)
  end

  test "a token past its life is refused", %{conn: conn} do
    old =
      Phoenix.Token.sign(KickTrackerWeb.Endpoint, "data v1", :page,
        signed_at: System.system_time(:second) - 7 * 3600
      )

    refute DataToken.valid?(old)
    assert json_response(get(put_req_header(conn, "x-data-token", old), @path), 403)
  end

  test "a request from another site's page is refused, even with a token", %{conn: conn} do
    for site <- ~w(cross-site same-site none) do
      assert json_response(get(put_req_header(conn, "sec-fetch-site", site), @path), 403),
             site
    end

    assert json_response(get(put_req_header(conn, "sec-fetch-site", "same-origin"), @path), 200)
  end

  test "every page carries a valid token", %{conn: conn} do
    html = html_response(get(conn, "/about/methodology"), 200)
    [_, token] = Regex.run(~r/<meta name="data-token" content="([^"]+)"/, html)
    assert DataToken.valid?(token)
  end

  test "a public page's LiveView hands out a fresh token", %{conn: conn} do
    {:ok, view, _} = live(conn, "/c/somestreamer")
    render_hook(view, "data_token", %{})
    assert_reply(view, %{token: token})
    assert DataToken.valid?(token)
  end
end
