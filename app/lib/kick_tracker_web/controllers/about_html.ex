defmodule KickTrackerWeb.AboutHTML do
  use KickTrackerWeb, :html

  embed_templates "about_html/*"

  @doc "Where privacy and removal requests go (`CONTACT_EMAIL`)."
  def contact,
    do: Application.get_env(:kick_tracker, :contact_email) || "the address given by the operator"
end
