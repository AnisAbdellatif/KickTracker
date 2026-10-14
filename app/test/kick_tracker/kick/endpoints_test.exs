defmodule KickTracker.Kick.EndpointsTest do
  use ExUnit.Case, async: true

  alias KickTracker.Kick.Endpoints

  test "our settings, in kicksdk's terms" do
    assert Endpoints.get(
             api_url: "https://api.kick.test",
             id_url: "https://id.kick.test",
             v2_url: "https://kick.test/api/v2/",
             realtime_url: "https://web.kick.test/api/v1/realtime"
           ) == %{
             api: "https://api.kick.test/public/v1",
             id: "https://id.kick.test",
             website: "https://kick.test",
             realtime: "https://web.kick.test/api/v1/realtime"
           }
  end

  test "a URL that isn't configured never becomes kicksdk's default, the real Kick" do
    endpoints = Endpoints.get(realtime_url: nil, id_url: "")
    assert endpoints.realtime =~ ".invalid"
    assert endpoints.id =~ ".invalid"

    request = Kicksdk.Realtime.token_request("c", endpoints)
    refute request["url"] =~ "kick.com"
  end
end
