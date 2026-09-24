-- Read-only users for the primary / shadow pair (project.md §10.5).
-- Replace CHANGE_ME with passwords kept in the secrets (secrets/README.md).

-- On the MAIN database: what the shadow reads (MAIN_DATABASE_URL).
CREATE ROLE shadow_reader LOGIN PASSWORD 'CHANGE_ME';
GRANT CONNECT ON DATABASE kick_tracker TO shadow_reader;
GRANT USAGE ON SCHEMA public TO shadow_reader;
GRANT SELECT ON channels, removals TO shadow_reader;

-- On the SHADOW database: what the primary side's backfill reads
-- (SHADOW_DATABASE_URL).
CREATE ROLE backfill_reader LOGIN PASSWORD 'CHANGE_ME';
GRANT CONNECT ON DATABASE kick_tracker TO backfill_reader;
GRANT USAGE ON SCHEMA public TO backfill_reader;
GRANT SELECT ON channels, streams, viewer_samples, stream_changes, categories,
  subscriber_samples, follower_samples, chat_minutes, chat_minute_users,
  kick_users, coverage, collector_nodes TO backfill_reader;
