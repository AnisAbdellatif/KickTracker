#!/bin/sh
# Restores the latest backup into a scratch container and checks it
# (project.md §18.1: "restore tested regularly, scripted"): the restored
# database must start, hold the main tables with about as many rows as the
# live one, and give the same figures for recent streams.
#
# Run from cron weekly, on any host with Docker and the backup credentials:
#   43 4 * * 0  cd /srv/kick_tracker/deploy && ./backup/restore-test.sh >> /var/log/kt-restore.log 2>&1
#
# Environment: DB_IMAGE (the database image with WAL-G), the WAL-G storage
# variables (WALG_S3_PREFIX + AWS_* or WALG_FILE_PREFIX, and
# WALG_LIBSODIUM_KEY if backups are encrypted), LIVE_DATABASE_URL (optional:
# to compare row counts), POSTGRES_USER / POSTGRES_DB, ALERT_WEBHOOK_URL,
# RESTORE_HEARTBEAT_URL, WALG_VOLUME (for WALG_FILE_PREFIX: a volume or
# path mounted at the prefix).
set -eu

DB_IMAGE=${DB_IMAGE:-kicktracker-db}
PGUSER=${POSTGRES_USER:-postgres}
PGDB=${POSTGRES_DB:-kick_tracker}
NAME=kt-restore-test-$$

say() { echo "$(date -u +%FT%TZ) $*"; }

notify() {
  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    curl -fsS -m 20 -H 'content-type: application/json' \
      -d "{\"content\":\"$1\",\"text\":\"$1\"}" "$ALERT_WEBHOOK_URL" >/dev/null || true
  fi
}

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
[ -n "${KEEP_RESTORE:-}" ] || trap cleanup EXIT

fail() {
  say "RESTORE TEST FAILED: $1"
  notify "🔴 restore test failed: $1"
  exit 1
}

envs=""
for v in $(env | grep -E '^(WALG_|AWS_)' | cut -d= -f1); do envs="$envs -e $v"; done
mount=""
if [ -n "${WALG_VOLUME:-}" ]; then mount="-v ${WALG_VOLUME}:${WALG_FILE_PREFIX}:ro"; fi

say "fetching the latest base backup"
# shellcheck disable=SC2086
docker run -d --name "$NAME" $envs $mount --entrypoint sleep "$DB_IMAGE" infinity >/dev/null
r() { docker exec -u postgres "$NAME" "$@"; }

r sh -c 'mkdir -p /tmp/restore && chmod 700 /tmp/restore && wal-g backup-fetch /tmp/restore LATEST' ||
  fail "backup-fetch"

say "replaying archived WAL"
r sh -c "cat >> /tmp/restore/postgresql.auto.conf <<CONF
restore_command = 'wal-g wal-fetch %f %p'
recovery_target_action = 'promote'
archive_mode = off
CONF
touch /tmp/restore/recovery.signal" || fail "recovery setup"

r sh -c 'pg_ctl -D /tmp/restore -l /tmp/restore.log -o "-c listen_addresses= -c port=5433" -w -t 600 start' ||
  { r cat /tmp/restore.log || true; fail "the restored database did not start"; }

q() { r psql -h /var/run/postgresql -p 5433 -U "$PGUSER" -d "$PGDB" -tAc "$1"; }

for i in $(seq 1 300); do
  [ "$(q 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ] && break
  sleep 2
done
[ "$(q 'SELECT pg_is_in_recovery()')" = "f" ] || fail "recovery did not finish"

say "checking tables"
for t in channels streams viewer_samples webhook_events stream_stats; do
  n=$(q "SELECT count(*) FROM $t") || fail "reading $t"
  say "  $t: $n rows"
  if [ -n "${LIVE_DATABASE_URL:-}" ]; then
    live=$(docker run --rm --network host "$DB_IMAGE" psql "$LIVE_DATABASE_URL" -tAc "SELECT count(*) FROM $t") ||
      fail "reading the live $t"
    # The backup can only be behind the live database, and not by much.
    [ "$n" -le "$live" ] || fail "$t has more rows restored ($n) than live ($live)"
    [ "$live" -eq 0 ] || [ $((n * 100 / live)) -ge 95 ] || fail "$t: $n restored of $live live"
  fi
done

say "checking figures"
# Every closed stream's stored hours watched must be what its samples give
# (the rollup's formula, §14): the restored data is internally consistent.
bad=$(q "
  WITH w AS (
    SELECT v.stream_id, v.viewers * LEAST(EXTRACT(EPOCH FROM v.observed_at - coalesce(
             lag(v.observed_at) OVER (PARTITION BY v.stream_id ORDER BY v.observed_at), s.started_at)), 75) AS vw
    FROM viewer_samples v JOIN streams s ON s.id = v.stream_id
    WHERE s.id IN (SELECT id FROM streams WHERE ended_at IS NOT NULL ORDER BY started_at DESC LIMIT 20)
  )
  SELECT count(*) FROM (
    SELECT w.stream_id, sum(greatest(vw, 0)) / 3600 AS hw FROM w GROUP BY 1
  ) x JOIN stream_stats st ON st.stream_id = x.stream_id
  WHERE abs(coalesce(st.hours_watched, 0) - x.hw) > 0.01 AND st.stream_id NOT IN (SELECT other_stream_id FROM merged_streams)
    AND st.stream_id NOT IN (SELECT stream_id FROM merged_streams)") || fail "computing figures"
[ "$bad" = "0" ] || fail "$bad recent streams' hours watched disagree with their samples"

say "restore test passed"
if [ -n "${RESTORE_HEARTBEAT_URL:-}" ]; then curl -fsS -m 20 "$RESTORE_HEARTBEAT_URL" >/dev/null || true; fi
