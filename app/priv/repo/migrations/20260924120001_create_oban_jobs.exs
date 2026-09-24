defmodule KickTracker.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  # Oban's own tables: follower polls, subscription sync, event retries.
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down(version: 1)
end
