#!/usr/bin/env bash
# Deploys one role (project.md §15.3, deploy/README.md), from deploy/:
#
#   ROLE=web APP_IMAGE=ghcr.io/<owner>/kicktracker-app:<sha> ./deploy.sh
#
# ROLE: web | collector | receivers | migrate-only | shadow.
# APP_IMAGE (and RECEIVER_IMAGE for receivers): the images to deploy.
# COMPOSE_FILES: overrides the compose files (the rehearsal adds its own).
#
# Every pair is updated one at a time, each waiting for the other to be
# healthy: web-a then web-b; the collectors' standby, then their leader
# (whose clean stop hands collection over within a second); receiver-1
# then receiver-2. Migrations run first, as their own step. Images are
# pinned in deploy/.env, so a plain `docker compose up -d` never swaps
# one by accident. The Deploy workflow runs this over SSH.
set -euo pipefail
cd "$(dirname "$0")"

: "${ROLE:?ROLE is web, collector, receivers, migrate-only or shadow}"
# An empty image means "not this one": compose must read the pin in .env,
# not an empty value from the environment.
[ -n "${APP_IMAGE:-}" ] || unset APP_IMAGE
[ -n "${RECEIVER_IMAGE:-}" ] || unset RECEIVER_IMAGE
touch .env

if [ "$ROLE" = shadow ]; then
  files=${COMPOSE_FILES:-compose.shadow.yml}
else
  files=${COMPOSE_FILES:-compose.single.yml}
fi
dc() {
  local args=()
  for f in $files; do args+=(-f "$f"); done
  docker compose "${args[@]}" "$@"
}

pin() {
  grep -v "^$1=" .env > .env.new || true
  echo "$1=$2" >> .env.new
  mv .env.new .env
}

# Compose needs every pin for any command; a first deploy sets whichever
# is missing to this image.
if [ "$ROLE" != shadow ]; then
  grep -q '^APP_IMAGE=' .env || pin APP_IMAGE "${APP_IMAGE:?}"
  grep -q '^COLLECTOR_IMAGE=' .env || pin COLLECTOR_IMAGE "${APP_IMAGE:?}"
fi

healthy() {
  for _ in $(seq 1 90); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q "$1")")" = healthy ] && return 0
    sleep 2
  done
  echo "$1 did not become healthy" >&2
  return 1
}

# Which collector collects now, from its status port inside the container.
leader() {
  for c in collector-a collector-b; do
    if dc exec -T "$c" curl -fsS http://127.0.0.1:4101/status 2>/dev/null | grep -q '"role":"leader"'; then
      echo "$c"
      return
    fi
  done
}

# Two of a kind, one at a time: the one not doing the main work first.
pair() {
  local first=$1 second=$2
  dc up -d --no-deps "$first"
  healthy "$first"
  dc up -d --no-deps "$second"
  healthy "$second"
}

collectors() {
  dc pull --policy missing collector-a collector-b
  if [ "$(leader)" = collector-b ]; then pair collector-a collector-b; else pair collector-b collector-a; fi
}

migrate() {
  dc pull --policy missing migrate
  dc run --rm migrate
}

case "$ROLE" in
  web)
    pin APP_IMAGE "${APP_IMAGE:?}"
    migrate
    dc pull --policy missing web-a web-b
    pair web-a web-b
    ;;
  migrate-only)
    migrate
    ;;
  collector)
    # Migrations from the new image; the web pin stays as it is. They wait
    # at most 5s for a lock, which the collectors' journals absorb.
    migrate
    pin COLLECTOR_IMAGE "${APP_IMAGE:?}"
    collectors
    ;;
  shadow)
    pin SHADOW_IMAGE "${APP_IMAGE:?}"
    migrate
    collectors
    ;;
  receivers)
    pin RECEIVER_IMAGE "${RECEIVER_IMAGE:?}"
    dc pull --policy missing receiver-1 receiver-2
    pair receiver-1 receiver-2
    ;;
  *)
    echo "unknown ROLE $ROLE" >&2
    exit 1
    ;;
esac

dc ps
