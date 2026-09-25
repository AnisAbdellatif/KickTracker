#!/usr/bin/env bash
# Deploys the shadow collector (project.md §10.5) on the stage 2 machine,
# which runs it with compose (compose.shadow.yml), from deploy/ in its
# checkout, after `git pull`:
#
#   ROLE=shadow ./deploy.sh
#
# The main VPS's app is deployed with deploy-kit and Kamal instead
# (release.sh); this script is only for the shadow. Which build: the one CI
# made of this checkout's commit, unless TAG names another (a sha, to roll
# back), or APP_IMAGE names the image outright. Migrations run first; then
# the two shadow collectors are updated one at a time, the standing-by one
# first, each waiting for the other to be healthy. The image is pinned in
# deploy/.env (SHADOW_IMAGE).
set -euo pipefail
cd "$(dirname "$0")"

: "${ROLE:?ROLE is shadow (the main VPS deploys with release.sh)}"
[ "$ROLE" = shadow ] || {
  echo "deploy.sh only deploys the shadow now; the main VPS: deploy/release.sh, or .kamal/kit/bin/kit (README.md)" >&2
  exit 1
}
# An empty image means "not this one": compose must read the pin in .env.
[ -n "${APP_IMAGE:-}" ] || unset APP_IMAGE
touch .env

# No image given: this checkout's build.
TAG=${TAG:-$(git rev-parse HEAD)}
IMAGE_PREFIX=${IMAGE_PREFIX:-ghcr.io/anisabdellatif/kicktracker}
APP_IMAGE=${APP_IMAGE:-$IMAGE_PREFIX-app:$TAG}

# The image is fetched before anything changes: a build that doesn't
# exist (CI still building it, or it failed) stops here, touching nothing.
docker image inspect "$APP_IMAGE" >/dev/null 2>&1 || docker pull -q "$APP_IMAGE" >/dev/null || {
  echo "no image $APP_IMAGE: has CI finished building it? Nothing was changed." >&2
  exit 1
}

files=${COMPOSE_FILES:-compose.shadow.yml}
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

healthy() {
  for _ in $(seq 1 90); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q "$1")")" = healthy ] && return 0
    sleep 2
  done
  echo "$1 did not become healthy" >&2
  return 1
}

# Which shadow collector collects now, from its status port.
leader() {
  for c in collector-a collector-b; do
    if dc exec -T "$c" curl -fsS http://127.0.0.1:4101/status 2>/dev/null | grep -q '"role":"leader"'; then
      echo "$c"
      return
    fi
  done
}

pair() {
  dc up -d --no-deps "$1"
  healthy "$1"
  dc up -d --no-deps "$2"
  healthy "$2"
}

pin SHADOW_IMAGE "$APP_IMAGE"
dc pull --policy missing migrate
dc run --rm migrate
dc pull --policy missing collector-a collector-b
if [ "$(leader)" = collector-b ]; then pair collector-a collector-b; else pair collector-b collector-a; fi
dc ps
