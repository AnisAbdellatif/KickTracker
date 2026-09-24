# Shared by the scripts cron runs on the host (backup/*.sh, ops/*.sh):
# cron starts them with an almost empty environment, so they read their
# settings from the decrypted secrets themselves, and say when they fail.
# Sourced, not run. Needs DEPLOY_DIR (the deploy/ folder) set first.

SECRETS_DIR=${SECRETS_DIR:-$DEPLOY_DIR/secrets}

# env_get KEY FILE...: KEY's value from the first of the env files that sets
# it to something non-empty. The files are parsed, never sourced (a value
# with spaces, like ADMIN_ALLOW, would run as a command); one pair of
# surrounding quotes is removed, as docker compose does.
env_get() {
  _key=$1
  shift
  for _file in "$@"; do
    [ -r "$_file" ] || continue
    _value=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$_key=//p" "$_file" | tail -n 1)
    case $_value in
      \"*\") _value=${_value#\"}; _value=${_value%\"} ;;
      \'*\') _value=${_value#\'}; _value=${_value%\'} ;;
    esac
    if [ -n "$_value" ]; then
      printf '%s\n' "$_value"
      return 0
    fi
  done
  return 0
}

# setting KEY FILE...: the environment's KEY if set, else from the files.
setting() {
  _key=$1
  shift
  eval "_env=\${$_key:-}"
  if [ -n "$_env" ]; then printf '%s\n' "$_env"; else env_get "$_key" "$@"; fi
}

# Where alerts go: the same settings as the app's (project.md §18.2).
load_alert_settings() {
  ALERT_WEBHOOK_URL=$(setting ALERT_WEBHOOK_URL "$SECRETS_DIR/collector.env" "$SECRETS_DIR/app.env")
  TELEGRAM_BOT_TOKEN=$(setting TELEGRAM_BOT_TOKEN "$SECRETS_DIR/collector.env" "$SECRETS_DIR/app.env")
  TELEGRAM_CHAT_ID=$(setting TELEGRAM_CHAT_ID "$SECRETS_DIR/collector.env" "$SECRETS_DIR/app.env")
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }

# alert MESSAGE: logs it, and sends it to the webhook and/or Telegram.
# Never fails (a broken alert channel mustn't hide the original error).
alert() {
  echo "$(date -u +%FT%TZ) ALERT: $1" >&2
  _msg="🔴 $(hostname): $1"
  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    _json=$(json_escape "$_msg")
    curl -fsS -m 20 -H 'content-type: application/json' \
      -d "{\"content\":\"$_json\",\"text\":\"$_json\"}" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 ||
      echo "could not reach ALERT_WEBHOOK_URL" >&2
  fi
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -m 20 --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$_msg" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null 2>&1 ||
      echo "could not reach Telegram" >&2
  fi
  if [ -z "${ALERT_WEBHOOK_URL:-}" ] && [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "no ALERT_WEBHOOK_URL or TELEGRAM_BOT_TOKEN set: this alert went nowhere" >&2
  fi
  return 0
}

# ping URL: a heartbeat (dead man's switch); never fails.
ping_url() {
  [ -n "${1:-}" ] || return 0
  curl -fsS -m 20 "$1" >/dev/null 2>&1 || echo "could not ping the heartbeat URL" >&2
}

# alert_on_failure WHAT: after this, any exit with an error status (set -e,
# a failed command, a signal) sends "WHAT failed", unless fail() already
# said why.
alert_on_failure() {
  _what=$1
  _alerted=
  trap '_status=$?; if [ "$_status" -ne 0 ] && [ -z "$_alerted" ]; then alert "$_what failed (exit $_status, see its log)"; fi; cleanup_hook' EXIT
  trap 'exit 130' INT TERM HUP
}

# fail MESSAGE: alerts with the reason and exits.
fail() {
  _alerted=1
  alert "${_what:-a scheduled job} failed: $1"
  exit 1
}

# Scripts define their own to remove temporary files and containers.
cleanup_hook() { :; }
