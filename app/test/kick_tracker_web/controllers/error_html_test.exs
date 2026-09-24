defmodule KickTrackerWeb.ErrorHTMLTest do
  use KickTrackerWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html as a page of the site, with a way home" do
    html = render_to_string(KickTrackerWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Page not found"
    assert html =~ ~r/<a[^>]* href="\/"/
    assert html =~ ~s(id="theme-toggle")
  end

  test "renders 500.html" do
    html = render_to_string(KickTrackerWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Something went wrong"
    assert html =~ "500"
  end

  test "renders other statuses by their name" do
    assert render_to_string(KickTrackerWeb.ErrorHTML, "400", "html", []) =~ "Bad Request"
  end
end
