#!/usr/bin/env bash
# A release (project.md §15.3), run from your machine, on main, once CI
# passed for the commit (its images are built, labelled and attested):
#
#   deploy/release.sh              the groups the release changes
#   deploy/release.sh --dry-run    say what would be deployed and why; deploy nothing
#   deploy/release.sh --all        every group, changed or not
#
# With deploy-kit (.kamal/) and Kamal (deploy/kamal/*.yml): the app, then
# the receivers. Only the groups whose code changed are deployed: a group
# is deployed when something it runs differs between the build it runs
# and this commit (the paths below); the others keep their build. Before
# anything is replaced, the kit checks the branch, a clean and pushed
# tree, CI green for this commit and the images' attestations, brings the
# server's checkout up to the commit and decrypts its secrets there
# (deploy/server-sync.sh), and runs the migrations. Then the collectors
# (the standby is updated, then takes over; the old leader stays on the
# previous build), the web nodes one at a time, the receivers one at a
# time, and the smoke tests through Caddy (KIT_SMOKE_URLS), which roll
# back what this release deployed if they fail. A step that fails stops
# the release; what wasn't reached keeps running the previous build.
#
# Other arguments go to the `kit deploy`s: `--version <sha>` deploys
# another commit's images (a rollback of web and the receivers; the
# collectors' rollback is `kit group switch collectors`).
set -euo pipefail
cd "$(dirname "$0")/.."

kit=.kamal/kit/bin/kit
die() { echo "release: $*" >&2 && exit 1; }

[ -f .kamal/kit.local.env ] || die "no .kamal/kit.local.env: copy .kamal/kit.local.env.example and fill it in"
# Without Kamal the kit can't tell what runs, and says so obscurely.
kamal=${KIT_KAMAL:-$(sed -n 's/^KIT_KAMAL=//p' .kamal/kit.env .kamal/kit.local.env | tail -n 1 | tr -d '"'"'")}
kamal=${kamal:-kamal}
command -v "${kamal%% *}" >/dev/null ||
  die "${kamal%% *} isn't on PATH (a user gem install puts it in $(ruby -e 'print Gem.user_dir' 2>/dev/null || echo '<gem user dir>')/bin)"

all=false dry_run=false target="" args=()
while [ $# -gt 0 ]; do
  case $1 in
    --all) all=true ;;
    --dry-run) dry_run=true ;;
    --version)
      [ $# -ge 2 ] || die "--version needs a commit"
      target=$2
      args+=("$1" "$2")
      shift
      ;;
    --version=*) target=${1#--version=} && args+=("$1") ;;
    *) args+=("$1") ;;
  esac
  shift
done
target=$(git rev-parse --verify "${target:-HEAD}^{commit}") || die "no commit ${target:-HEAD} here"

# What each group runs, as paths of this repo: its image's build context
# (CI's, .github/workflows/ci.yml), its Kamal config and its secrets. Kept
# strict on purpose: a path missing here leaves a group on stale code.
app=(app ":(exclude)app/test" ":(exclude,glob)app/**/*.md" deploy/kamal/app.yml)
# What only web nodes run, checked 2026-09-25: a collector never starts the
# endpoint, and from the web layer uses only KickTrackerWeb.Telemetry,
# Layouts.site_name and the endpoint's configuration (config/, not here).
web_only=(
  app/assets app/priv/static app/priv/gettext
  app/lib/kick_tracker_web/live app/lib/kick_tracker_web/controllers
  app/lib/kick_tracker_web/plugs app/lib/kick_tracker_web/components/layouts
  app/lib/kick_tracker_web/components/core_components.ex
  app/lib/kick_tracker_web/components/site_components.ex
  app/lib/kick_tracker_web/components/page_params.ex
  app/lib/kick_tracker_web/router.ex app/lib/kick_tracker_web/endpoint.ex
  app/lib/kick_tracker_web/admin_auth.ex app/lib/kick_tracker_web/period.ex
  app/lib/kick_tracker_web/not_found_error.ex app/lib/kick_tracker_web/gettext.ex
)
paths_of() {
  local p
  case $1 in
    web) printf '%s\n' "${app[@]}" deploy/secrets/app.sops.env ;;
    collectors)
      printf '%s\n' "${app[@]}" deploy/secrets/collector.sops.env
      for p in "${web_only[@]}"; do printf ':(exclude)%s\n' "$p"; done
      ;;
    receivers)
      printf '%s\n' ingress/receiver ":(exclude)ingress/receiver/test" ":(exclude,glob)ingress/receiver/**/*.md" \
        deploy/kamal/receiver.yml deploy/secrets/receiver.sops.env
      ;;
    *) die "no paths for group $1: add them to deploy/release.sh" ;;
  esac
}

# running GROUP: the builds GROUP runs, one per line, "-" for a role that
# runs nothing. For a standby group, only the active role's: the standby
# is one build behind on purpose and is updated by the next deploy anyway.
running() {
  "$kit" group status "$1" | awk '
    NR == 1 { standby = ($0 ~ /\(standby\)$/); next }
    {
      v = ($2 == "(not") ? "-" : $2
      sub(/_replaced_.*/, "", v)  # a container Kamal renamed aside
      if (!standby) print v
      else if ($NF == "active") { print v; found = 1 }
    }
    END { if (standby && !found) print "-" }'
}

# why GROUP: why GROUP needs this release, or nothing if it doesn't.
why() {
  local base files path paths=()
  while IFS= read -r path; do paths+=("$path"); done < <(paths_of "$1")
  while IFS= read -r base; do
    if [ "$base" = - ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
      echo "runs ${base:0:12}, which isn't a commit here"
      return
    fi
    files=$(git diff --name-only "$base" "$target" -- "${paths[@]}")
    if [ -n "$files" ]; then
      echo "changed since ${base:0:7}: $(printf '%s\n' "$files" | head -3 | tr '\n' ' ')$([ "$(printf '%s\n' "$files" | wc -l)" -gt 3 ] && echo '…')"
      return
    fi
  done < <(running "$1")
}

deploy_config() { # CONFIG GROUP...
  local config=$1 g reason selected=()
  shift
  for g in "$@"; do
    if [ "$all" = true ]; then
      reason="--all"
    else
      reason=$(why "$g")
    fi
    if [ -n "$reason" ]; then
      echo "release: $g: deploy ($reason)"
      selected+=(--group "$g")
    else
      echo "release: $g: unchanged since the build it runs, not deployed"
    fi
  done
  [ ${#selected[@]} -gt 0 ] && [ "$dry_run" = false ] || return 0
  "$kit" deploy -c "$config" "${selected[@]}" ${args[@]+"${args[@]}"}
}

echo "release: ${target:0:7}$([ "$dry_run" = true ] && echo ' (dry run: nothing is deployed)')"
deploy_config deploy/kamal/app.yml collectors web
deploy_config deploy/kamal/receiver.yml receivers
