#!/usr/bin/env bash
# Tests what deploy/shadow.sh asks the kit for: in a throwaway git repo
# with a fake kit (the build each group runs, the deploys asked for).
# No server, no Docker.
#
#   deploy/shadow-test.sh
set -euo pipefail
for var in $(compgen -e | grep -E '^(KT|KIT)_' || true); do unset "$var"; done
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

cd "$tmp"
git init -q -b main
git config user.email tester@example.com
git config user.name tester
git config commit.gpgsign false
mkdir -p deploy .kamal/kit/bin
cp "$here/shadow.sh" deploy/shadow.sh
cat >.kamal/kit/bin/kit <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "group status")
    var="RUNNING_$(printf '%s' "$3" | tr '[:lower:]-' '[:upper:]_')"
    echo "$3 (rolling)"
    printf '  %-20s %-14s %s\n' role "${!var:-(not}" healthy
    ;;
  "deploy "*) echo "$* | $KIT_NOTIFY_PREFIX" >>"$CALLS" ;;
esac
SH
chmod +x .kamal/kit/bin/kit deploy/shadow.sh
git add -A && git commit -qm one
one=$(git rev-parse HEAD)
git commit -qm two --allow-empty
two=$(git rev-parse HEAD)
export CALLS="$tmp/calls"

run() { : >"$CALLS"; deploy/shadow.sh "$@" >"$tmp/out" 2>&1 || true; }
check() {
  if [ "$(cat "$CALLS")" = "$2" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    echo "  wanted: $(printf '%s' "$2" | tr '\n' '|')"
    echo "  got:    $(tr '\n' '|' <"$CALLS")"
    sed 's/^/  /' "$tmp/out"
    failures=$((failures + 1))
  fi
}

export RUNNING_SHADOW=$one RUNNING_BACKUP_RECEIVER=$one
run
check "both groups to this checkout's commit, each with its own config, no smoke tests" \
  "deploy -c deploy/kamal/shadow.yml --group shadow --version $two --no-smoke | [kicktracker/shadow]
deploy -c deploy/kamal/backup-receiver.yml --group backup-receiver --version $two --no-smoke | [kicktracker/shadow]"

run --version "${one:0:7}"
check "a group already on the build is left alone" ""

export RUNNING_SHADOW=$two
run
check "only the one behind" \
  "deploy -c deploy/kamal/backup-receiver.yml --group backup-receiver --version $two --no-smoke | [kicktracker/shadow]"

export RUNNING_SHADOW=$one
run --only shadow
check "--only" "deploy -c deploy/kamal/shadow.yml --group shadow --version $two --no-smoke | [kicktracker/shadow]"

run --dry-run
check "--dry-run deploys nothing" ""
run --status
check "--status deploys nothing" ""
if grep -q "shadow: $one" "$tmp/out"; then
  echo "ok: --status says what runs"
else
  echo "FAIL: --status output" && failures=$((failures + 1))
fi

unset RUNNING_SHADOW
run --only shadow
check "a first deploy (nothing running yet)" "deploy -c deploy/kamal/shadow.yml --group shadow --version $two --no-smoke | [kicktracker/shadow]"

run --only nope
check "an unknown group is refused" ""

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
