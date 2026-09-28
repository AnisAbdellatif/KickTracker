#!/usr/bin/env bash
# Deploys the shadow machine (project.md §10.5, §15.2) with deploy-kit: the
# shadow collector (group `shadow`, deploy/kamal/shadow.yml) and the backup
# receiver (group `backup-receiver`, deploy/kamal/backup-receiver.yml), each
# one role replaced in place. Run it by hand at any time, from a checkout of
# main on any machine with the kit's settings for the shadow machine
# (.kamal/kit.local.env: KT_SHADOW_HOST, KT_SHADOW_SSH_USER,
# KT_SHADOW_DEPLOY_DIR); the follower (deploy/shadow-follow.sh) runs it on
# its own once a build has been live and healthy on the main VPS for a
# while.
#
#   deploy/shadow.sh                      # this checkout's commit
#   deploy/shadow.sh --version <sha>      # another build (a rollback, say)
#   deploy/shadow.sh --only shadow        # or --only backup-receiver
#   deploy/shadow.sh --status             # what each runs, nothing deployed
#   deploy/shadow.sh --dry-run            # what would be deployed
#
# A group already on the build is left alone. Everything else is the kit's
# usual deploy (the same gates as the main VPS: branch, clean and pushed
# tree, CI green, the images' attestations; then server-sync and the
# shadow's own migrations on the shadow machine), without the main VPS's
# smoke tests: each group waits for its role to be healthy instead, and
# puts the previous build back if it never is. Other arguments go to
# `kit deploy`.
set -euo pipefail
cd "$(dirname "$0")/.."

kit=.kamal/kit/bin/kit
die() { echo "shadow: $*" >&2 && exit 1; }

version="" only="" status=false dry_run=false args=()
while [ $# -gt 0 ]; do
  case $1 in
    --version) version=${2:?--version needs a commit} && shift ;;
    --only) only=${2:?--only needs shadow or backup-receiver} && shift ;;
    --status) status=true ;;
    --dry-run) dry_run=true ;;
    *) args+=("$1") ;;
  esac
  shift
done

groups="shadow backup-receiver"
if [ -n "$only" ]; then
  case " $groups " in *" $only "*) groups=$only ;; *) die "--only: shadow or backup-receiver, not $only" ;; esac
fi

config_of() {
  case $1 in
    shadow) echo deploy/kamal/shadow.yml ;;
    backup-receiver) echo deploy/kamal/backup-receiver.yml ;;
  esac
}

# running GROUP: the build GROUP's role runs ("-" for none).
running() {
  "$kit" group status "$1" | awk 'NR > 1 { v = ($2 == "(not") ? "-" : $2; sub(/_replaced_.*/, "", v); print v; exit }'
}

if [ "$status" = true ]; then
  for g in $groups; do echo "$g: $(running "$g")"; done
  exit 0
fi

target=$(git rev-parse --verify "${version:-HEAD}^{commit}" 2>/dev/null) || die "no commit ${version:-HEAD} here (git fetch?)"

# The shadow machine's own settings: its notifications say so, and the
# main VPS's smoke URLs never judge it (a shadow deploy while the main VPS
# is down must still work). KT_* and KIT_* from the environment beat the
# kit's files.
export KIT_NOTIFY_PREFIX="${KIT_NOTIFY_PREFIX:-[kicktracker/shadow]}"
export KIT_SMOKE_URLS=""

echo "shadow: ${target:0:7}$([ "$dry_run" = true ] && echo ' (dry run: nothing is deployed)')"
for g in $groups; do
  now=$(running "$g")
  if [ "$now" = "$target" ]; then
    echo "shadow: $g: already on ${target:0:7}"
    continue
  fi
  echo "shadow: $g: ${now:0:7} -> ${target:0:7}"
  [ "$dry_run" = true ] && continue
  "$kit" deploy -c "$(config_of "$g")" --group "$g" --version "$target" --no-smoke ${args[@]+"${args[@]}"}
done
