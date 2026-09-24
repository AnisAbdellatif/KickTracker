defmodule Mix.Tasks.KickTracker.Admin.Invite do
  @shortdoc "Prints an invitation link for a new admin"

  @moduledoc """
  Invites an admin (project.md §13.8): the first one, or one more when no
  one can log in. Prints the link to send them; it works once, for 7 days.

      mix kick_tracker.admin.invite someone@example.com

  In a release: `bin/kick_tracker eval 'KickTracker.Release.invite("someone@example.com")'`.
  """

  use Mix.Task

  @impl true
  def run([email]) do
    Mix.Task.run("app.config")
    Application.put_env(:kick_tracker, :collect, false)
    Application.put_env(:kick_tracker, :role, "collector")
    Mix.Task.run("app.start")
    Mix.shell().info(KickTracker.Release.invite_link(email))
  end

  def run(_), do: Mix.raise("usage: mix kick_tracker.admin.invite EMAIL")
end
