#!/bin/sh
# Mirrors WAL-G's store (the `backups` volume, WALG_FILE_PREFIX=/backups)
# to Filen with rclone (project.md §18.1), so the backups outlive the VPS.
# The store is already encrypted (WALG_LIBSODIUM_KEY); Filen sees only
# ciphertext. A mirror: what WAL-G prunes is removed from Filen too (into
# its trash).
#
# Run from cron every 5 minutes, as the user that deploys (it reads the
# decrypted secrets and runs docker):
#   */5 * * * *  /srv/kick_tracker/deploy/backup/offsite-sync.sh >> "$HOME/kt-offsite.log" 2>&1
#
# Needs nothing from cron's environment. From secrets/offsite.env: rclone's
# Filen remote (RCLONE_CONFIG_FILEN_*), OFFSITE_PATH (the folder on Filen),
# OFFSITE_HEARTBEAT_URL (pinged on success); from secrets/collector.env or
# app.env: ALERT_WEBHOOK_URL / TELEGRAM_* / NTFY_* (told about any failure).
# Also: BACKUP_VOLUME (default kicktracker_backups), RCLONE_IMAGE,
# MAX_DELETE (default 5000).
set -eu

DEPLOY_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DEPLOY_DIR/ops/common.sh"

OFFSITE_ENV=$SECRETS_DIR/offsite.env
BACKUP_VOLUME=${BACKUP_VOLUME:-kicktracker_backups}
RCLONE_IMAGE=${RCLONE_IMAGE:-rclone/rclone:1.75.1}
# A day of WAL is 1 440 files (a segment a minute), and one base backup
# goes each day: the daily pruning stays well under this. An emptied or
# replaced volume is refused before this (below).
MAX_DELETE=${MAX_DELETE:-5000}
LOCK=${OFFSITE_LOCK:-$HOME/.kt-offsite.lock}
FAILURES=${OFFSITE_FAILURES:-$HOME/.kt-offsite.failures}

# The first upload, or one after an outage, can outlast the 5 minutes:
# the next run leaves it alone rather than racing it.
exec 9>"$LOCK"
flock -n 9 || { echo "$(date -u +%FT%TZ) a sync is still running"; exit 0; }

load_alert_settings
alert_on_failure "the off-site backup sync"

[ -r "$OFFSITE_ENV" ] || fail "no $OFFSITE_ENV (copy offsite.env.example to offsite.sops.env and fill it in)"
OFFSITE_PATH=$(setting OFFSITE_PATH "$OFFSITE_ENV")
OFFSITE_PATH=${OFFSITE_PATH:-kicktracker-backups}
# A mirror makes the folder match the store: pointed at the drive's root,
# it would delete everything else in the account.
case $(printf '%s' "$OFFSITE_PATH" | tr -d '/. ') in
  "") fail "OFFSITE_PATH ($OFFSITE_PATH) is the drive's root: it must be a folder of its own" ;;
esac
OFFSITE_HEARTBEAT_URL=$(setting OFFSITE_HEARTBEAT_URL "$OFFSITE_ENV")
docker volume inspect "$BACKUP_VOLUME" >/dev/null 2>&1 || fail "no volume $BACKUP_VOLUME"

# A store without WAL is a new or emptied volume, never one in use (WAL is
# pushed every minute): mirroring it would empty Filen, so it's refused.
# --max-delete only stops a sync after that many deletions.
[ -n "$(docker run --rm -v "$BACKUP_VOLUME:/backups:ro" "$RCLONE_IMAGE" lsf --files-only /backups/wal_005 -q 2>/dev/null | head -n 1)" ] ||
  fail "$BACKUP_VOLUME holds no WAL (wal_005 is empty or missing): not mirroring it to Filen"

echo "$(date -u +%FT%TZ) sync to filen:$OFFSITE_PATH"
# WAL-G writes each file under a temporary name (<name>.tmp.<time>-<hex>)
# and renames it once complete and synced: those are skipped, so nothing
# half-written is copied.
if docker run --rm --env-file "$OFFSITE_ENV" -v "$BACKUP_VOLUME:/backups:ro" "$RCLONE_IMAGE" \
  sync /backups "filen:$OFFSITE_PATH" --exclude '*.tmp.*' --max-delete "$MAX_DELETE" --stats 0 -q; then
  rm -f "$FAILURES"
else
  # Filen or the network having a bad few minutes isn't news: alert after
  # 3 failed runs in a row (15 minutes), then hourly while it lasts. The
  # heartbeat stops either way.
  n=$(($(cat "$FAILURES" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$FAILURES"
  if [ "$n" -eq 3 ] || [ $((n % 12)) -eq 0 ]; then
    fail "rclone sync to filen:$OFFSITE_PATH ($n runs in a row)"
  fi
  _alerted=1
  exit 1
fi

ping_url "$OFFSITE_HEARTBEAT_URL"
echo "$(date -u +%FT%TZ) done"
