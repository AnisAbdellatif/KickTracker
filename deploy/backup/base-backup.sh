#!/bin/sh
# A full base backup to object storage, and pruning of old ones (project.md
# §18.1). WAL is archived continuously by the database itself (archive.conf),
# so any moment since the oldest kept base backup can be restored.
#
# Run from cron on the database host, daily, as the user that deploys
# (it reads the decrypted secrets and runs docker):
#   17 2 * * *  /srv/kick_tracker/deploy/backup/base-backup.sh >> "$HOME/kt-backup.log" 2>&1
#
# Needs nothing from cron's environment: WAL-G's storage settings are the
# database container's own (secrets/db.env); BACKUP_HEARTBEAT_URL (pinged
# on success) is read from secrets/db.env, and ALERT_WEBHOOK_URL / TELEGRAM_*
# (told about any failure) from secrets/collector.env or app.env. Each can
# be overridden from the environment, as can COMPOSE_FILE (default
# compose.single.yml) and KEEP_FULL (default 7).
set -eu

DEPLOY_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DEPLOY_DIR/ops/common.sh"
cd "$DEPLOY_DIR"

load_alert_settings
alert_on_failure "the daily base backup"

COMPOSE_FILE=${COMPOSE_FILE:-compose.single.yml}
KEEP_FULL=${KEEP_FULL:-7}
BACKUP_HEARTBEAT_URL=$(setting BACKUP_HEARTBEAT_URL "$SECRETS_DIR/db.env")

# WAL-G connects to the database as PGUSER: the role the image created
# (POSTGRES_USER), not the OS user `postgres`, which has no role of that
# name. Both come from the container's own environment (secrets/db.env).
db() {
  docker compose -f "$COMPOSE_FILE" exec -T -u postgres db \
    sh -c 'PGUSER="$POSTGRES_USER" PGDATABASE="${POSTGRES_DB:-$POSTGRES_USER}" PGHOST=/var/run/postgresql exec "$@"' sh "$@"
}

echo "$(date -u +%FT%TZ) base backup"
db sh -c 'wal-g backup-push "$PGDATA"' || fail "backup-push"
db wal-g delete retain FULL "$KEEP_FULL" --confirm || fail "pruning old backups"
db wal-g backup-list || true

ping_url "$BACKUP_HEARTBEAT_URL"
echo "$(date -u +%FT%TZ) done"
