#!/usr/bin/env bash
# The follower (project.md §10.5): brings the shadow machine up to what the
# main VPS runs, once that has been live and healthy there for a while.
# Run every 10 minutes by a systemd timer on the shadow machine
# (deploy/shadow/kicktracker-follow.timer), from a checkout of main that
# only deploys (deploy/README.md, "The shadow machine").
#
# Each run:
#   1. reads what the main VPS runs: the leading collector's build (its
#      collector_nodes row, through the shadow's read-only user) and the
#      receivers' build (the webhook hostname's /health: the ingress Worker
#      sends it to the main VPS first; one the backup answered, by its
#      x-ingress-target header, isn't the main VPS's and counts as
#      unhealthy);
#   2. says whether the main VPS is healthy: a leader heard from in the
#      last 90s, no open alert, the site's /healthz and the receivers'
#      /health answering;
#   3. per group (shadow: the collectors' build; backup-receiver: the
#      receivers'), keeps a soak clock: it starts when a build is first
#      seen healthy, and any unhealthy run starts it again;
#   4. once a build has been healthy for KT_SHADOW_SOAK (default 6h), and
#      the follower hasn't already brought that build over, deploys it
#      (deploy/shadow.sh --only <group> --version <build>).
#
# It follows the main VPS changing, not what the shadow runs: a build
# deployed by hand (deploy/shadow.sh) stays until the main VPS moves on.
# A failed deploy is tried again after KT_FOLLOW_RETRY (default 1h).
#
#   deploy/shadow-follow.sh            # one run (what the timer does)
#   deploy/shadow-follow.sh --status   # the soak clocks, nothing deployed
#   deploy/shadow-follow.sh --now      # deploy the main VPS's builds now,
#                                      # whatever the clock or the health
#   deploy/shadow-follow.sh --pause    # the timer's runs do nothing
#   deploy/shadow-follow.sh --resume
#
# Settings (the environment, or .kamal/kit.local.env, parsed here, never
# sourced): KT_SHADOW_SOAK (6h; s, m, h, d or seconds), KT_FOLLOW_RETRY
# (1h), KT_FOLLOW_SITE_HEALTH (the site's /healthz URL),
# KT_FOLLOW_INGRESS_HEALTH (the webhook hostname's /health),
# KT_FOLLOW_MAIN_DB_URL (default: MAIN_DATABASE_URL from the
# shadow's decrypted shadow.env under KT_SHADOW_DEPLOY_DIR), KT_FOLLOW_PSQL
# (the psql command; default psql), KT_FOLLOW_STATE (the state folder;
# default ~/.local/state/kicktracker-follow).
set -euo pipefail

say() { echo "follow: $*"; }
die() { echo "follow: $*" >&2 && exit 1; }

# setting NAME DEFAULT: from the environment, else kit.local.env, else DEFAULT.
setting() {
  if [ -n "${!1:-}" ]; then
    printf '%s' "${!1}"
  elif [ -f .kamal/kit.local.env ] && grep -qE "^$1=" .kamal/kit.local.env; then
    sed -n "s/^$1=//p" .kamal/kit.local.env | tail -n 1 | sed -E "s/^([\"'])(.*)\\1\$/\\2/"
  else
    printf '%s' "$2"
  fi
}

# seconds 6h -> 21600
seconds() {
  case $1 in
    *d) echo $((${1%d} * 86400)) ;;
    *h) echo $((${1%h} * 3600)) ;;
    *m) echo $((${1%m} * 60)) ;;
    *s) echo "${1%s}" ;;
    *[!0-9]* | "") die "not a duration: '$1' (e.g. 6h, 90m, 2d)" ;;
    *) echo "$1" ;;
  esac
}

# state GROUP KEY [VALUE]: reads, or writes, one value of GROUP's state.
state() {
  local f="$state_dir/$1"
  if [ $# -eq 3 ]; then
    touch "$f"
    { grep -v "^$2=" "$f" || true; printf '%s=%s\n' "$2" "$3"; } >"$f.new"
    mv "$f.new" "$f"
  else
    [ -f "$f" ] && sed -n "s/^$2=//p" "$f" | tail -n 1
    return 0
  fi
}

# The main VPS's database, read-only: ecto:// in shadow.env becomes postgresql://.
main_db_url() {
  local url env_file
  url=$(setting KT_FOLLOW_MAIN_DB_URL "")
  if [ -z "$url" ]; then
    env_file="$(setting KT_SHADOW_DEPLOY_DIR /srv/kick_tracker)/deploy/secrets/shadow.env"
    [ -f "$env_file" ] || die "no KT_FOLLOW_MAIN_DB_URL, and no $env_file to read MAIN_DATABASE_URL from"
    url=$(sed -n 's/^MAIN_DATABASE_URL=//p' "$env_file" | tail -n 1)
  fi
  [ -n "$url" ] || die "MAIN_DATABASE_URL is empty"
  printf '%s' "${url/#ecto:\/\//postgresql://}"
}

query() {
  # shellcheck disable=SC2086 # KT_FOLLOW_PSQL may be a command with arguments
  $psql "$db_url" -XAtq -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

# observe: sets collectors_build, receivers_build, healthy, problems.
observe() {
  local alerts body headers
  problems=""
  collectors_build=$(query "SELECT status->>'build' FROM collector_nodes
    WHERE state = 'leader' AND heartbeat_at > now() - interval '90 seconds'
    ORDER BY heartbeat_at DESC LIMIT 1") || { collectors_build=""; problems="$problems; its database can't be read"; }
  [ -n "$collectors_build" ] || problems="$problems; no collector leading"
  if alerts=$(query "SELECT count(*) FROM alerts WHERE resolved_at IS NULL"); then
    [ "$alerts" = 0 ] || problems="$problems; $alerts open alert(s)"
  fi
  curl -fsS -m 10 -o /dev/null "$site_health" 2>/dev/null || problems="$problems; the site's /healthz doesn't answer"
  headers=$state_dir/.health-headers
  if body=$(curl -fsS -m 10 -D "$headers" "$ingress_health" 2>/dev/null); then
    receivers_build=$(printf '%s' "$body" | sed -n 's/.*"build":"\([0-9a-f]\{40\}\)".*/\1/p')
    [ -n "$receivers_build" ] || problems="$problems; the receivers' /health says no build"
    if grep -qi '^x-ingress-target: *backup' "$headers" 2>/dev/null; then
      receivers_build=""
      problems="$problems; the backup receiver answered /health, not the main VPS"
    fi
  else
    receivers_build=""
    problems="$problems; the receivers' /health doesn't answer"
  fi
  problems=${problems#; }
  if [ -z "$problems" ]; then healthy=true; else healthy=false; fi
}

# follow GROUP BUILD: the soak clock for GROUP, and its deploy when due.
follow() {
  local group=$1 build=$2 since deployed failed failed_at age
  if [ -z "$build" ]; then
    # Not seeing it is as good as unhealthy: the clock starts again.
    say "$group: the main VPS's build can't be seen: waiting"
    state "$group" since ""
    return 0
  fi
  if [ "$(state "$group" build)" != "$build" ]; then
    state "$group" build "$build"
    state "$group" since ""
  fi
  if [ "$healthy" != true ] && [ "$force" != true ]; then
    [ -n "$(state "$group" since)" ] && say "$group: the soak clock for ${build:0:7} starts again ($problems)"
    state "$group" since ""
    return 0
  fi
  since=$(state "$group" since)
  if [ -z "$since" ]; then
    since=$now
    state "$group" since "$since"
  fi
  deployed=$(state "$group" deployed)
  if [ "$deployed" = "$build" ] && [ "$force" != true ]; then
    return 0
  fi
  age=$((now - since))
  if [ "$age" -lt "$soak" ] && [ "$force" != true ]; then
    say "$group: ${build:0:7} healthy on the main VPS for $((age / 60))m of $((soak / 60))m"
    return 0
  fi
  failed=$(state "$group" failed)
  failed_at=$(state "$group" failed_at)
  if [ "$failed" = "$build" ] && [ $((now - ${failed_at:-0})) -lt "$retry" ] && [ "$force" != true ]; then
    say "$group: ${build:0:7} failed to deploy $(((now - failed_at) / 60))m ago: trying again after $((retry / 60))m"
    return 0
  fi
  say "$group: ${build:0:7} has been live and healthy on the main VPS for $((age / 60))m: deploying it"
  if "$shadow" --only "$group" --version "$build"; then
    state "$group" deployed "$build"
    state "$group" failed ""
  else
    state "$group" failed "$build"
    state "$group" failed_at "$now"
    say "$group: deploying ${build:0:7} failed (the kit has notified)"
    return 1
  fi
}

# The checkout up to origin's main first, so what deploys is current
# (this script included: bash has already read it, main is one function).
update_checkout() {
  git fetch -q origin
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "this checkout isn't on main"
  git merge -q --ff-only origin/main || die "this checkout can't fast-forward to origin/main (local changes?)"
}

main() {
  cd "$(dirname "$0")/.."
  local mode=run status=0
  case ${1:-} in
    "") ;;
    --status | --now | --pause | --resume) mode=${1#--} ;;
    *) die "usage: deploy/shadow-follow.sh [--status | --now | --pause | --resume]" ;;
  esac

  state_dir=$(setting KT_FOLLOW_STATE "${XDG_STATE_HOME:-$HOME/.local/state}/kicktracker-follow")
  mkdir -p "$state_dir"
  case $mode in
    pause) touch "$state_dir/paused" && say "paused: runs do nothing until --resume" && return 0 ;;
    resume) rm -f "$state_dir/paused" && say "resumed" && return 0 ;;
  esac
  if [ -f "$state_dir/paused" ] && [ "$mode" = run ]; then
    say "paused (deploy/shadow-follow.sh --resume)"
    return 0
  fi

  soak=$(seconds "$(setting KT_SHADOW_SOAK 6h)")
  retry=$(seconds "$(setting KT_FOLLOW_RETRY 1h)")
  site_health=$(setting KT_FOLLOW_SITE_HEALTH "")
  ingress_health=$(setting KT_FOLLOW_INGRESS_HEALTH "")
  [ -n "$site_health" ] || die "KT_FOLLOW_SITE_HEALTH isn't set (the site's /healthz)"
  [ -n "$ingress_health" ] || die "KT_FOLLOW_INGRESS_HEALTH isn't set (the webhook hostname's /health)"
  psql=$(setting KT_FOLLOW_PSQL psql)
  shadow=${KT_FOLLOW_SHADOW_SH:-deploy/shadow.sh}
  now=${KT_FOLLOW_NOW:-$(date +%s)}
  force=false
  [ "$mode" = now ] && force=true
  db_url=$(main_db_url)

  [ "$mode" = status ] || [ "${KT_FOLLOW_NO_FETCH:-}" = true ] || update_checkout

  observe
  if [ "$healthy" = true ]; then
    say "the main VPS is healthy: collectors ${collectors_build:0:7}, receivers ${receivers_build:0:7}"
  else
    say "the main VPS isn't healthy: $problems"
  fi

  if [ "$mode" = status ]; then
    local g since
    for g in shadow backup-receiver; do
      since=$(state "$g" since)
      say "$g: following $(state "$g" build | cut -c1-7), healthy since $([ -n "$since" ] && date -d "@$since" '+%F %T' || echo '-'), last brought over $(state "$g" deployed | cut -c1-7)"
    done
    return 0
  fi

  follow shadow "$collectors_build" || status=1
  follow backup-receiver "$receivers_build" || status=1
  return $status
}

# One line: bash reads a script as it runs it, and update_checkout may
# rewrite this file; nothing after this line is ever read.
main "$@"; exit
