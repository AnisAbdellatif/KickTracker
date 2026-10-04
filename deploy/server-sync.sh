#!/usr/bin/env bash
# Runs on the server before each deploy (the kit's server-sync step,
# .kamal/steps/server-sync), as the deploy user, in its checkout:
#
#   deploy/server-sync.sh <commit being deployed>
#
# Brings the checkout up to that commit (compose files, Caddy's sites, the
# cron scripts and the encrypted secrets all live there), decrypts the
# secrets the containers read, and moves the app's containers off the
# `always` restart policy. A deploy of an older commit (a rollback)
# leaves the checkout where it is: newer secrets and config serve older
# builds too (expand-then-contract, §15.3).
set -euo pipefail
cd "$(dirname "$0")/.."

commit=${1:?usage: deploy/server-sync.sh <commit>}
[[ $commit =~ ^[0-9a-f]{7,40}$ ]] || { echo "not a commit id: $commit" >&2; exit 1; }

git fetch --quiet origin
if ! git merge-base --is-ancestor "$commit" HEAD; then
  git merge --ff-only --quiet "$commit" || {
    echo "the checkout can't fast-forward to $commit (local changes, or not on main?): nothing deployed" >&2
    exit 1
  }
fi
echo "checkout at $(git rev-parse --short HEAD)"
deploy/secrets/decrypt.sh

# The app's containers (collectors, web nodes, the shadow) are restarted
# `unless-stopped` (deploy/kamal/app.yml): a build Kamal stopped stays
# stopped when the Docker daemon restarts. Containers created while they
# were `always` keep that until Kamal prunes them, and are still the ones a
# rollback starts: changed here, on every machine a deploy reaches.
docker ps -aq --filter label=service=kicktracker |
  xargs -r docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' |
  awk '$2 == "always" { sub("^/", "", $1); print $1 }' |
  while read -r name; do
    docker update --restart=unless-stopped "$name" >/dev/null
    echo "restart policy of $name: always -> unless-stopped"
  done
