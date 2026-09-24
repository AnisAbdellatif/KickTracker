defmodule KickTracker.OtherSide do
  @moduledoc """
  A second, real database standing for the other side of a primary /
  shadow pair (project.md §10.5): the shadow's database in backfill
  tests, the primary's in shadow-sync tests. Same schema, reached over a
  real connection like in production, outside the test sandbox (tests
  using it aren't async and start from `reset!/0`).
  """

  @database "kick_tracker_other_test"

  @doc "Creates and migrates the database once (from test_helper), with the app's migrations."
  def setup! do
    _ = Ecto.Adapters.Postgres.storage_up(KickTracker.OtherRepo.config())
    {:ok, pid} = KickTracker.OtherRepo.start_link()
    Ecto.Migrator.run(KickTracker.OtherRepo, :up, all: true, log: false)
    Supervisor.stop(pid)
    :ok
  end

  @doc "Its `ecto://` URL."
  def url do
    c = KickTracker.Repo.config()

    "ecto://#{c[:username]}:#{c[:password]}@#{c[:hostname]}:#{c[:port] || 5432}/#{@database}"
  end

  @doc "Runs SQL there; returns the rows."
  def query!(sql, params \\ []) do
    {:ok, rows} = KickTracker.Collector.Remote.with_conn(url(), fn q -> q.(sql, params) end)
    rows
  end

  @doc "Empties every table the tests use."
  def reset! do
    query!("""
    TRUNCATE chat_minute_users, chat_minutes, chat_stream_users, stream_changes, viewer_samples,
      subscriber_samples, follower_samples, coverage, streams, categories, kick_users, removals,
      collector_nodes, channel_slugs, channels CASCADE
    """)
  end
end
