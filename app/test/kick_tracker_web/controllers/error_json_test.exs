defmodule KickTrackerWeb.ErrorJSONTest do
  use KickTrackerWeb.ConnCase, async: true

  test "renders 404" do
    assert KickTrackerWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert KickTrackerWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
