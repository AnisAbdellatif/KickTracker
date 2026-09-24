#!/usr/bin/env bash
# Deploys one role (project.md §15.3, deploy/README.md), from deploy/,
# after `git pull` on the server's checkout of main:
#
#   ROLE=web ./deploy.sh
#
# ROLE: web | collector | collector-switch | receivers | migrate-only | shadow.
# Which build: the one CI made of this checkout's commit (images are
# tagged with the main commit they were built from), unless TAG names
# another (a sha, to roll back), or APP_IMAGE (and RECEIVER_IMAGE for
# receivers) names the image outright. migrate-only runs the pinned one.
# COMPOSE_FILES: overrides the compose files (the rehearsal adds its own).
#
# Web and receiver pairs are updated one at a time, each waiting for the
# other to be healthy: web-a then web-b, receiver-1 then receiver-2.
# The collectors are not both updated: only the one standing by gets the
# new build, then collection is switched to it (the leader restarts in
# place, on the build it had, and its clean stop hands collection over
# within a second). The old leader stays on the previous build as the
# standby, so rolling back is switching back:
#
#   ROLE=collector-switch ./deploy.sh
#
# Each collector has its own pin (COLLECTOR_A_IMAGE, COLLECTOR_B_IMAGE).
# Migrations run first, as their own step. Images are pinned in
# deploy/.env, so a plain `docker compose up -d` never swaps one by
# accident. The Deploy workflow runs this over SSH.
set -euo pipefail
cd "$(dirname "$0")"

: "${ROLE:?ROLE is web, collector, receivers, migrate-only or shadow}"
# An empty image means "not this one": compose must read the pin in .env,
# not an empty value from the environment.
[ -n "${APP_IMAGE:-}" ] || unset APP_IMAGE
[ -n "${RECEIVER_IMAGE:-}" ] || unset RECEIVER_IMAGE
touch .env

# No image given: this checkout's build.
TAG=${TAG:-$(git rev-parse HEAD)}
IMAGE_PREFIX=${IMAGE_PREFIX:-ghcr.io/anisabdellatif/kicktracker}
case "$ROLE" in
  web | collector | shadow) APP_IMAGE=${APP_IMAGE:-$IMAGE_PREFIX-app:$TAG} ;;
  collector-switch) ;;
  receivers) RECEIVER_IMAGE=${RECEIVER_IMAGE:-$IMAGE_PREFIX-receiver:$TAG} ;;
esac

# The image is fetched before anything changes: a build that doesn't
# exist (CI still building it, or it failed) stops here, touching nothing.
fetch() {
  docker image inspect "$1" >/dev/null 2>&1 && return 0
  docker pull -q "$1" >/dev/null || {
    echo "no image $1: has CI finished building it (Actions, CI, Images)? Nothing was changed." >&2
    exit 1
  }
}
case "$ROLE" in
  web | collector | shadow) fetch "$APP_IMAGE" ;;
  receivers) fetch "$RECEIVER_IMAGE" ;;
esac

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

pinned() { grep "^$1=" .env | tail -1 | cut -d= -f2-; }

# Compose needs every pin for any command; a first deploy sets whichever
# is missing to this image. A collector without its own pin yet keeps the
# build both ran under the shared COLLECTOR_IMAGE, so it isn't swapped.
if [ "$ROLE" != shadow ] && [ "$ROLE" != collector-switch ]; then
  grep -q '^APP_IMAGE=' .env || pin APP_IMAGE "${APP_IMAGE:?}"
  grep -q '^COLLECTOR_IMAGE=' .env || pin COLLECTOR_IMAGE "${APP_IMAGE:?}"
fi
if [ "$ROLE" != shadow ]; then
  for c in A B; do
    grep -q "^COLLECTOR_${c}_IMAGE=" .env || pin "COLLECTOR_${c}_IMAGE" "$(pinned COLLECTOR_IMAGE)"
  done
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

other() { if [ "$1" = collector-a ]; then echo collector-b; else echo collector-a; fi; }
pin_name() { if [ "$1" = collector-a ]; then echo COLLECTOR_A_IMAGE; else echo COLLECTOR_B_IMAGE; fi; }

# Hands collection from the leader to the standby: the leader restarts in
# place (same container, same build), and its clean stop releases the
# lease to the standby, which must be healthy first. Fails if the standby
# didn't end up collecting.
switch_to() {
  local to=$1 from
  from=$(other "$to")
  healthy "$to"
  if [ "$(leader)" != "$to" ]; then
    dc restart -t 60 "$from"
    healthy "$from"
  fi
  for _ in $(seq 1 30); do
    [ "$(leader)" = "$to" ] && { echo "$to collects; $from stands by"; return 0; }
    sleep 1
  done
  echo "$to did not take over collection (leader: $(leader || true))" >&2
  return 1
}

# The standby gets this build, then collects; the leader keeps its build
# and stands by (a rollback is `collector-switch`). With nobody leading
# (a first deploy), collector-b is updated and collector-a kept.
collector_deploy() {
  local current standby
  current=$(leader)
  current=${current:-collector-a}
  standby=$(other "$current")
  pin "$(pin_name "$standby")" "${APP_IMAGE:?}"
  dc up -d --no-deps "$standby"
  switch_to "$standby"
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
    # at most 5s for a lock, which the collectors' journals absorb. The
    # build left standing by must work on the migrated schema too, which
    # expand-then-contract migrations guarantee.
    migrate
    pin COLLECTOR_IMAGE "${APP_IMAGE:?}"
    collector_deploy
    ;;
  collector-switch)
    # Back to the build the standby runs (the previous one after a deploy).
    current=$(leader)
    switch_to "$(other "${current:-collector-b}")"
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
