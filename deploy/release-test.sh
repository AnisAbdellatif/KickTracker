#!/usr/bin/env bash
# Tests which groups deploy/release.sh deploys: in a throwaway git repo
# laid out like this one, with a fake kit (the builds each group runs, the
# deploys it was asked for) and a fake kamal on PATH. No server, no Docker.
#
#   deploy/release-test.sh
set -euo pipefail
# Whatever this shell exports for the kit or the server isn't the test's.
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
mkdir -p deploy/kamal deploy/secrets .kamal/kit/bin bin \
  app/lib/kick_tracker app/lib/kick_tracker_web/live app/lib/kick_tracker_web/components app/assets/js app/test \
  ingress/receiver/src ingress/receiver/test
cp "$here/release.sh" deploy/release.sh
touch .kamal/kit.env .kamal/kit.local.env deploy/kamal/app.yml deploy/kamal/receiver.yml \
  deploy/secrets/app.sops.env deploy/secrets/collector.sops.env deploy/secrets/receiver.sops.env \
  app/lib/kick_tracker/collector.ex app/lib/kick_tracker_web/live/page.ex app/lib/kick_tracker_web/telemetry.ex \
  app/lib/kick_tracker_web/components/layouts.ex app/lib/kick_tracker_web/components/core_components.ex \
  app/assets/js/app.js app/test/page_test.exs app/mix.lock app/README.md \
  ingress/receiver/src/main.rs ingress/receiver/test/main_test.rs
# The fake kit: `group status` from $RUNNING_<GROUP> ("role version
# [active]" per line), `deploy` recorded.
cat >.kamal/kit/bin/kit <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "group status")
    var="RUNNING_$(printf '%s' "$3" | tr '[:lower:]' '[:upper:]')"
    [ "$3" = collectors ] && echo "collectors (standby)" || echo "$3 (rolling)"
    printf '%s\n' "${!var}" | while read -r role v activity; do
      printf '  %-20s %-14s %-10s %s\n' "$role" "$v" healthy "$activity"
    done
    ;;
  "deploy "*) echo "$*" >>"$CALLS" ;;
esac
SH
printf '#!/bin/sh\n' >bin/kamal
chmod +x .kamal/kit/bin/kit bin/kamal deploy/release.sh
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls"
git add -A && git commit -qm base
base=$(git rev-parse HEAD)

# every group running BASE (collector_a active), then a release of HEAD.
release() {
  : >"$CALLS"
  RUNNING_COLLECTORS="collector_a $base active
collector_b $base standby" RUNNING_WEB="web_a $base
web_b $base" RUNNING_RECEIVERS="receiver_1 $base
receiver_2 $base" deploy/release.sh "$@" >"$tmp/out" 2>&1
}

# expect NAME CHANGE-FILES... -- EXPECTED-DEPLOY-CALLS...
expect() {
  local name=$1 files=() want=() got
  shift
  while [ "$1" != -- ]; do files+=("$1") && shift; done
  shift
  want=("$@")
  git checkout -q "$base"
  for f in "${files[@]}"; do echo change >>"$f"; done
  git commit -qam "$name"
  release
  got=$(cat "$CALLS")
  if [ "$got" = "$(printf '%s\n' ${want[@]+"${want[@]}"} | sed '/^$/d')" ]; then
    echo "ok: $name"
  else
    echo "FAIL: $name"
    echo "  wanted: $(printf '%s | ' ${want[@]+"${want[@]}"})"
    echo "  got:    $(tr '\n' '|' <"$CALLS")"
    sed 's/^/  /' "$tmp/out"
    failures=$((failures + 1))
  fi
}

A="deploy -c deploy/kamal/app.yml"
R="deploy -c deploy/kamal/receiver.yml"
expect "web-only code: web alone" app/assets/js/app.js app/lib/kick_tracker_web/live/page.ex -- "$A --group web"
expect "a web component the collector uses: both" app/lib/kick_tracker_web/components/layouts.ex -- "$A --group collectors --group web"
expect "web telemetry, which the collector starts: both" app/lib/kick_tracker_web/telemetry.ex -- "$A --group collectors --group web"
expect "shared code: collectors and web" app/lib/kick_tracker/collector.ex -- "$A --group collectors --group web"
expect "dependencies: collectors and web" app/mix.lock -- "$A --group collectors --group web"
expect "the app's Kamal config: collectors and web" deploy/kamal/app.yml -- "$A --group collectors --group web"
expect "the collectors' secrets: collectors alone" deploy/secrets/collector.sops.env -- "$A --group collectors"
expect "the web secrets: web alone" deploy/secrets/app.sops.env -- "$A --group web"
expect "receiver code: receivers alone" ingress/receiver/src/main.rs -- "$R --group receivers"
expect "tests and docs only: nothing" app/test/page_test.exs app/README.md ingress/receiver/test/main_test.rs --
expect "everything: all three" app/lib/kick_tracker/collector.ex ingress/receiver/src/main.rs -- \
  "$A --group collectors --group web" "$R --group receivers"

verdict() { # ok|fail NAME
  if [ "$1" = ok ]; then
    echo "ok: $2"
  else
    echo "FAIL: $2 (deployed: $(tr '\n' '|' <"$CALLS"))"
    sed 's/^/  /' "$tmp/out"
    failures=$((failures + 1))
  fi
}

# --all deploys every group; --dry-run deploys nothing; unknown builds deploy.
git checkout -q "$base"
release --all
if [ "$(cat "$CALLS")" = "$(printf '%s\n' "$A --group collectors --group web" "$R --group receivers")" ]; then
  verdict ok "--all"
else
  verdict fail "--all"
fi

echo change >>app/lib/kick_tracker/collector.ex && git commit -qam dry
release --dry-run
if [ ! -s "$CALLS" ] && grep -q "collectors: deploy" "$tmp/out"; then
  verdict ok "--dry-run"
else
  verdict fail "--dry-run"
fi

git checkout -q "$base"
: >"$CALLS"
RUNNING_COLLECTORS="collector_a 0123456789abcdef_replaced_1 active
collector_b $base standby" RUNNING_WEB="web_a $base
web_b (not running)" RUNNING_RECEIVERS="receiver_1 ${base}_replaced_ab12
receiver_2 $base" deploy/release.sh >"$tmp/out" 2>&1
if [ "$(cat "$CALLS")" = "$A --group collectors --group web" ]; then
  verdict ok "a build that isn't a commit, or a role not running, deploys; a renamed container is its build"
else
  verdict fail "unknown builds"
fi

# A KT_* variable in the environment would beat .kamal/kit.local.env: refused.
echo change >>app/lib/kick_tracker/collector.ex && git commit -qam env
: >"$CALLS"
if ! KT_HOST=203.0.113.9 release >/dev/null 2>&1 && [ ! -s "$CALLS" ] && grep -q "KT_HOST" "$tmp/out"; then
  verdict ok "a KT_* variable in the shell is refused before anything is deployed"
else
  verdict fail "KT_* in the shell"
fi

[ "$failures" -eq 0 ] || { echo "$failures failed" && exit 1; }
echo "all passed"
