#!/bin/sh
# A full base backup to object storage, and pruning of old ones (project.md
# §18.1). WAL is archived continuously by the database itself (archive.conf),
# so any moment since the oldest kept base backup can be restored.
#
# Run from cron on the database host, daily:
#   17 2 * * *  cd /srv/kick_tracker/deploy && ./backup/base-backup.sh >> /var/log/kt-backup.log 2>&1
#
# Environment (from the same .env as the stack): COMPOSE_FILE (default
# compose.single.yml), KEEP_FULL (default 7), ALERT_WEBHOOK_URL (told on
# failure), BACKUP_HEARTBEAT_URL (pinged on success).
set -eu

COMPOSE_FILE=${COMPOSE_FILE:-compose.single.yml}
KEEP_FULL=${KEEP_FULL:-7}
db() { docker compose -f "$COMPOSE_FILE" exec -T -u postgres db "$@"; }

fail() {
  echo "base backup failed: $1" >&2
  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    curl -fsS -m 20 -H 'content-type: application/json' \
      -d "{\"content\":\"🔴 backup failed: $1\",\"text\":\"🔴 backup failed: $1\"}" "$ALERT_WEBHOOK_URL" || true
  fi
  exit 1
}

echo "$(date -u +%FT%TZ) base backup"
db sh -c 'wal-g backup-push "$PGDATA"' || fail "backup-push"
db wal-g delete retain FULL "$KEEP_FULL" --confirm || fail "pruning old backups"
db wal-g backup-list || true

if [ -n "${BACKUP_HEARTBEAT_URL:-}" ]; then curl -fsS -m 20 "$BACKUP_HEARTBEAT_URL" >/dev/null || true; fi
echo "$(date -u +%FT%TZ) done"
