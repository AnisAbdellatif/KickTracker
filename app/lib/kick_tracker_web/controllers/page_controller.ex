defmodule KickTrackerWeb.PageController do
  use KickTrackerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
