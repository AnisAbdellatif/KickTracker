defmodule KickTracker.Repo.Migrations.StreamStatsNewChatters do
  use Ecto.Migration

  # Chatters seen in the channel for the first time (since tracking began)
  # in this stream. Derived like the rest of stream_stats; null until the
  # next rollup computes it.
  def change do
    alter table(:stream_stats) do
      add :new_chatters, :integer
    end
  end
end
