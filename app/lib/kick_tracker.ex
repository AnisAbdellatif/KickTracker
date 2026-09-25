defmodule KickTracker do
  @moduledoc """
  KickTracker keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc "The commit this node's image was built from (`BUILD_SHA`), or nil outside an image."
  @spec build() :: String.t() | nil
  def build, do: Application.get_env(:kick_tracker, :build)
end
