#!/usr/bin/env bash
# Deploys everything (project.md §19.1), from the server's checkout of
# main, after `git pull`: CI runs it after every merge to main, and by hand
# it is
#
#   git pull && deploy/release.sh
#
# The secrets are decrypted (the server's age key), then each role is
# deployed with deploy.sh, one at a time and each pair one at a time: the
# collectors first (standby, then leader), web, then the receivers. A step
# that fails stops the release; what was deployed stays, the rest keeps
# running the previous version.
#
# TAG: which build (default: this checkout's commit, see deploy.sh).
set -euo pipefail
cd "$(dirname "$0")"

# Secrets: written next to the old ones, then swapped, so a failed
# decryption leaves the running configuration as it was.
for f in secrets/*.sops.env; do
  out="${f%.sops.env}.env"
  if ! (umask 077 && sops --decrypt "$f" > "$out.new"); then
    rm -f "$out.new"
    echo "could not decrypt $f (is the server's age key in place?): nothing deployed" >&2
    exit 1
  fi
  mv "$out.new" "$out"
done

for role in collector web receivers; do
  echo "== $role"
  ROLE=$role ./deploy.sh
done
