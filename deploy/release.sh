#!/usr/bin/env bash
# A release (project.md §15.3), run from your machine, on main, once CI
# passed for the commit (its images are built, labelled and attested):
#
#   deploy/release.sh
#
# With deploy-kit (.kamal/) and Kamal (deploy/kamal/*.yml): the app, then
# the receivers. Before anything is replaced, the kit checks the branch,
# a clean and pushed tree, CI green for this commit and the images'
# attestations, brings the server's checkout up to the commit and decrypts
# its secrets there (deploy/server-sync.sh), and runs the migrations. Then
# the collectors (the standby is updated, then takes over; the old leader
# stays on the previous build), the web nodes one at a time, the receivers
# one at a time, and the smoke tests through Caddy (KIT_SMOKE_URLS), which
# roll a failed release back. A step that fails stops the release; what
# wasn't reached keeps running the previous build.
#
# Arguments go to both `kit deploy`s: `--version <sha>` deploys another
# commit's images (a rollback of web and the receivers; the collectors'
# rollback is `kit group switch collectors`).
set -euo pipefail
cd "$(dirname "$0")/.."

kit=.kamal/kit/bin/kit
[ -f .kamal/kit.local.env ] || {
  echo "no .kamal/kit.local.env: copy .kamal/kit.local.env.example and fill it in" >&2
  exit 1
}
"$kit" deploy -c deploy/kamal/app.yml "$@"
"$kit" deploy -c deploy/kamal/receiver.yml "$@"
