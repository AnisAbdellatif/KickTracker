#!/bin/sh
# Host checks the app can't do itself (project.md §18.2): disk space and
# certificate expiry. Run from cron every 15 minutes, as the user that
# deploys (it reads the decrypted secrets):
#   */15 * * * *  /srv/kick_tracker/deploy/ops/check-host.sh
# Tells ALERT_WEBHOOK_URL / Telegram / ntfy (from secrets/collector.env or
# app.env) about problems; checks the certificates of SITE_HOST and INGRESS_HOST
# (secrets/stack.env), or of HOSTS if set.
set -u

DEPLOY_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DEPLOY_DIR/ops/common.sh"
load_alert_settings

DISK_MAX=${DISK_MAX:-85}
CERT_MIN_DAYS=${CERT_MIN_DAYS:-14}
# stack.env is read, not sourced: ADMIN_ALLOW holds space-separated CIDRs.
HOSTS=${HOSTS:-"$(setting SITE_HOST "$SECRETS_DIR/stack.env") $(setting INGRESS_HOST "$SECRETS_DIR/stack.env")"}

df -P / /var/lib/docker 2>/dev/null | tail -n +2 | while read -r _ _ _ _ use mount; do
  pct=${use%\%}
  [ "$pct" -ge "$DISK_MAX" ] && alert "disk $mount is ${pct}% full"
done

for h in $HOSTS; do
  # A host that accepts the connection and never answers mustn't hang cron.
  end=$(echo | timeout 10 openssl s_client -servername "$h" -connect "$h:443" 2>/dev/null |
    openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$end" ]; then alert "no certificate readable for $h"; continue; fi
  days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
  [ "$days" -lt "$CERT_MIN_DAYS" ] && alert "the certificate for $h expires in $days days"
done
exit 0
