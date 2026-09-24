defmodule KickTracker.Repo.Migrations.MergeGroupsAndUnknownSupport do
  use Ecto.Migration

  # Expand only: two new views and a replaced one with the same columns,
  # and NOT NULL dropped from five derived columns. Code of the previous
  # release keeps working against all of it.
  def up do
    # Merges resolved transitively (project.md §13.8): every merged
    # stream with the root of its group, the stream nothing is merged
    # above. `merged_streams` is one level deep; a chain a <- b <- d
    # (merged one at a time) gives (a, b) and (a, d) here. Merges only go
    # into an earlier stream, so the recursion ends.
    execute("""
    CREATE VIEW merge_groups AS
    WITH RECURSIVE g(root_id, stream_id) AS (
      SELECT m.stream_id, m.other_stream_id FROM merged_streams m
      WHERE m.stream_id NOT IN (SELECT other_stream_id FROM merged_streams)
      UNION ALL
      SELECT g.root_id, m.other_stream_id FROM g JOIN merged_streams m ON m.stream_id = g.stream_id
    )
    SELECT root_id, stream_id FROM g
    """)

    # An excluded stream takes the streams merged into it along: they are
    # shown, and counted, as part of it.
    execute("""
    CREATE OR REPLACE VIEW excluded_streams AS
    SELECT stream_id FROM stream_overrides
    WHERE kind = 'exclude' AND revoked_at IS NULL
    UNION
    SELECT g.stream_id FROM merge_groups g
    JOIN stream_overrides o ON o.stream_id = g.root_id AND o.kind = 'exclude' AND o.revoked_at IS NULL
    """)

    # Webhook counts are unknown (null), not 0, when ingress coverage
    # doesn't cover the stream (project.md §12.6 "Unknown is null").
    for column <- ~w(follows subs resubs gifted_subs kicks)a do
      execute("ALTER TABLE stream_stats ALTER COLUMN #{column} DROP NOT NULL")
    end
  end

  def down do
    execute("""
    CREATE OR REPLACE VIEW excluded_streams AS
    SELECT DISTINCT stream_id FROM stream_overrides
    WHERE kind = 'exclude' AND revoked_at IS NULL
    """)

    execute("DROP VIEW merge_groups")
    # NOT NULL isn't restored: rows may hold nulls by then.
  end
end
