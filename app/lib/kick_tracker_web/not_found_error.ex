defmodule KickTrackerWeb.NotFoundError do
  @moduledoc "Raised for a page that doesn't exist (an unknown channel, stream or category): a 404."
  defexception message: "not found", plug_status: 404
end
