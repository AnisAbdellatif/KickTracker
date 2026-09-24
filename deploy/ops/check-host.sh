#!/bin/sh
# Host checks the app can't do itself (project.md §18.2): disk space and
# certificate expiry. Run from cron every 15 minutes:
#   */15 * * * *  /srv/kick_tracker/deploy/ops/check-host.sh
# Tells ALERT_WEBHOOK_URL (Discord/Slack) about problems; set HOSTS to the
# public hostnames to check.
set -u
[ -f "$(dirname "$0")/../secrets/stack.env" ] && . "$(dirname "$0")/../secrets/stack.env"
[ -f "$(dirname "$0")/../secrets/app.env" ] && ALERT_WEBHOOK_URL=$(grep '^ALERT_WEBHOOK_URL=' "$(dirname "$0")/../secrets/app.env" | cut -d= -f2-)

DISK_MAX=${DISK_MAX:-85}
CERT_MIN_DAYS=${CERT_MIN_DAYS:-14}
HOSTS=${HOSTS:-"${SITE_HOST:-} ${INGRESS_HOST:-}"}

alert() {
  echo "$1"
  [ -n "${ALERT_WEBHOOK_URL:-}" ] && curl -fsS -m 20 -H 'content-type: application/json' \
    -d "{\"content\":\"🔴 $1\",\"text\":\"🔴 $1\"}" "$ALERT_WEBHOOK_URL" >/dev/null
}

df -P / /var/lib/docker 2>/dev/null | tail -n +2 | while read -r _ _ _ _ use mount; do
  pct=${use%\%}
  [ "$pct" -ge "$DISK_MAX" ] && alert "disk $mount is ${pct}% full on $(hostname)"
done

for h in $HOSTS; do
  end=$(echo | openssl s_client -servername "$h" -connect "$h:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$end" ]; then alert "no certificate readable for $h"; continue; fi
  days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
  [ "$days" -lt "$CERT_MIN_DAYS" ] && alert "the certificate for $h expires in $days days"
done
exit 0
