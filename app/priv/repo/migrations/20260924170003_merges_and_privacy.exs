defmodule KickTracker.Repo.Migrations.MergesAndPrivacy do
  use Ecto.Migration

  def change do
    # Streams an admin merged into an earlier one (stream_overrides): the
    # other stream is shown as part of the first.
    execute(
      """
      CREATE VIEW merged_streams AS
      SELECT DISTINCT ON (other_stream_id) other_stream_id, stream_id FROM stream_overrides
      WHERE kind = 'merge' AND revoked_at IS NULL
      ORDER BY other_stream_id, inserted_at DESC
      """,
      "DROP VIEW merged_streams"
    )

    # A deletion request (project.md §13.8) removes the follower's id from
    # their follows but keeps the follow counted.
    alter table(:follows) do
      modify :user_id, :bigint, null: true, from: {:bigint, null: false}
    end

    # A body redacted for a deletion request no longer verifies against
    # Kick's signature; this says so.
    alter table(:webhook_events) do
      add :redacted_at, :timestamptz
    end
  end
end
