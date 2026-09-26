defmodule Sim.AssetsTest do
  use ExUnit.Case, async: false

  test "the pictures it hands out are served, as PNGs, at the address it was given" do
    start_supervised!({Sim.Instance, port: 0, asset_url: "http://sim.example:4050"})
    assert Application.get_env(:sim, :asset_url) == "http://sim.example:4050"

    %{status: 200, body: png, headers: headers} =
      Req.get!(Sim.Instance.base_url() <> "/assets/profile/somestreamer.png", decode_body: false)

    assert headers["content-type"] == ["image/png"]
    assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>> = png
    assert png == Sim.Png.solid(64, Sim.Png.colour("profile/somestreamer.png"))
  end
end
