#!/bin/sh
# Restores the latest backup into a scratch container and checks it
# (project.md §18.1: "restore tested regularly, scripted"): the restored
# database must start, hold the main tables with about as many rows as the
# live one, and give the same figures for recent streams.
#
# Run from cron weekly, as the user that deploys (it reads the decrypted
# secrets and runs docker):
#   43 4 * * 0  /srv/kick_tracker/deploy/backup/restore-test.sh >> "$HOME/kt-restore.log" 2>&1
#
# Needs nothing from cron's environment. From secrets/db.env: the WAL-G
# storage settings (every WALG_* and AWS_* line), POSTGRES_USER and
# POSTGRES_DB, RESTORE_HEARTBEAT_URL (pinged on success); from
# secrets/collector.env or app.env: ALERT_WEBHOOK_URL / TELEGRAM_* / NTFY_*
# (told about any failure). The environment overrides any of them, so it can
# run on another host with only the storage variables exported. Also:
#   DB_IMAGE           the database image with WAL-G (default: DB_IMAGE in
#                      deploy/.env, else the one compose.single.yml uses)
#   LIVE_DATABASE_URL  compare row counts with this database; by default
#                      they're compared with the stack's own `db` when it
#                      runs on this host (through `docker compose exec`)
#   COMPOSE_FILE       default compose.single.yml
#   WALG_VOLUME        for WALG_FILE_PREFIX: a volume or path mounted there
#   KEEP_RESTORE       set: leave the scratch container for a look
set -eu

DEPLOY_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DEPLOY_DIR/ops/common.sh"
cd "$DEPLOY_DIR"

load_alert_settings
alert_on_failure "the weekly restore test"

DB_ENV=$SECRETS_DIR/db.env
COMPOSE_FILE=${COMPOSE_FILE:-compose.single.yml}
DB_IMAGE=${DB_IMAGE:-$(env_get DB_IMAGE "$DEPLOY_DIR/.env")}
DB_IMAGE=${DB_IMAGE:-ghcr.io/anisabdellatif/kicktracker-db:latest}
PG_USER=$(setting POSTGRES_USER "$DB_ENV")
PG_USER=${PG_USER:-kick_tracker}
PG_DB=$(setting POSTGRES_DB "$DB_ENV")
PG_DB=${PG_DB:-$PG_USER}
RESTORE_HEARTBEAT_URL=$(setting RESTORE_HEARTBEAT_URL "$DB_ENV")
NAME=kt-restore-test-$$
ENV_FILE=$(mktemp)

say() { echo "$(date -u +%FT%TZ) $*"; }

cleanup_hook() {
  rm -f "$ENV_FILE"
  [ -n "${KEEP_RESTORE:-}" ] || docker rm -f "$NAME" >/dev/null 2>&1 || true
}

# WAL-G's settings for the scratch container: db.env's, then the
# environment's (later lines win). Only those: no database password.
chmod 600 "$ENV_FILE"
if [ -r "$DB_ENV" ]; then
  grep -E '^(WALG|AWS)_[A-Za-z0-9_]*=' "$DB_ENV" | sed "s/=[\"']\(.*\)[\"']$/=\1/" >>"$ENV_FILE" || true
fi
env | grep -E '^(WALG|AWS)_[A-Za-z0-9_]*=' >>"$ENV_FILE" || true
grep -qE '^WALG_(S3|FILE|GS|AZ|SWIFT|SSH)_PREFIX=.' "$ENV_FILE" ||
  fail "no WAL-G storage configured (WALG_S3_PREFIX in $DB_ENV or the environment)"

WALG_FILE_PREFIX=${WALG_FILE_PREFIX:-$(env_get WALG_FILE_PREFIX "$ENV_FILE")}
mount=""
if [ -n "${WALG_VOLUME:-}" ]; then mount="-v ${WALG_VOLUME}:${WALG_FILE_PREFIX}:ro"; fi

say "fetching the latest base backup ($DB_IMAGE)"
# shellcheck disable=SC2086
docker run -d --name "$NAME" --env-file "$ENV_FILE" $mount --entrypoint sleep "$DB_IMAGE" infinity >/dev/null ||
  fail "could not start a scratch container from $DB_IMAGE"
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

q() { r psql -h /var/run/postgresql -p 5433 -U "$PG_USER" -d "$PG_DB" -tAc "$1"; }

for _ in $(seq 1 300); do
  [ "$(q 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ] && break
  sleep 2
done
[ "$(q 'SELECT pg_is_in_recovery()')" = "f" ] || fail "recovery did not finish"

# The live database, to compare row counts with: LIVE_DATABASE_URL, or the
# stack's db on this host (inside its network: it needs no published port
# and no password), or none.
if [ -n "${LIVE_DATABASE_URL:-}" ]; then
  LIVE=url
elif [ -n "$(docker compose -f "$COMPOSE_FILE" ps -q db 2>/dev/null)" ]; then
  LIVE=compose
else
  LIVE=none
  say "no live database here to compare row counts with (set LIVE_DATABASE_URL)"
fi

live() {
  case $LIVE in
    url) docker run --rm --network host "$DB_IMAGE" psql "$LIVE_DATABASE_URL" -tAc "$1" ;;
    compose)
      # shellcheck disable=SC2016
      docker compose -f "$COMPOSE_FILE" exec -T db \
        sh -c 'psql -U "$POSTGRES_USER" -d "${POSTGRES_DB:-$POSTGRES_USER}" -tAc "$1"' sh "$1"
      ;;
  esac
}

say "checking tables"
for t in channels streams viewer_samples webhook_events stream_stats; do
  n=$(q "SELECT count(*) FROM $t") || fail "reading $t"
  say "  $t: $n rows"
  if [ "$LIVE" != none ]; then
    live_n=$(live "SELECT count(*) FROM $t") || fail "reading the live $t"
    # The backup can only be behind the live database, and not by much.
    [ "$n" -le "$live_n" ] || fail "$t has more rows restored ($n) than live ($live_n)"
    [ "$live_n" -eq 0 ] || [ $((n * 100 / live_n)) -ge 95 ] || fail "$t: $n restored of $live_n live"
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
ping_url "$RESTORE_HEARTBEAT_URL"
