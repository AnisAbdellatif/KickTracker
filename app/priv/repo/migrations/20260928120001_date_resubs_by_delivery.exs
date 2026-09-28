defmodule KickTracker.Repo.Migrations.DateResubsByDelivery do
  use Ecto.Migration

  # Resubs were dated by the body's `created_at`, which on a renewal is
  # when the subscription first started (KICK.md §4.1), months or years
  # before the renewal: they counted in periods before the channel was
  # tracked and in none of the streams they happened in. This dates each
  # stored one by its delivery, the stored webhook's `occurred_at`, as
  # `Events.Facts` now does for new ones, and queues a rollups job for
  # every hour a resub left or joined, so `hourly_stats` and `stream_stats`
  # follow. A resub whose webhook is gone keeps its time. Data only, and
  # running it twice changes nothing; old and new code both work with it.
  # Not reversible (the old dates are still in the webhook bodies).
  def up, do: Enum.each(statements(), &execute/1)

  def down, do: :ok

  # Apart, so a test can run them against stored rows.
  @doc false
  def statements do
    [
      """
      WITH moved AS (
        UPDATE support_events s SET occurred_at = m.new_at
        FROM (SELECT e.message_id, e.occurred_at AS old_at, w.occurred_at AS new_at
              FROM support_events e JOIN webhook_events w ON w.message_id = e.message_id
              WHERE e.kind = 'resub' AND e.occurred_at <> w.occurred_at) m
        WHERE s.message_id = m.message_id
        RETURNING m.old_at, m.new_at
      ),
      hours AS (
        SELECT DISTINCT date_trunc('hour', at, 'UTC') AS hour
        FROM moved, LATERAL (VALUES (old_at), (new_at)) v(at)
      )
      INSERT INTO oban_jobs (worker, queue, args, max_attempts)
      SELECT 'KickTracker.Workers.Reprocess', 'kick',
             jsonb_build_object(
               'kind', 'rollups',
               'from', to_char(hour AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
               'to', to_char((hour + interval '3599 seconds') AT TIME ZONE 'UTC',
                             'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
             3
      FROM hours
      """
    ]
  end
end
