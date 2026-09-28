#!/usr/bin/env bash
# Tests when deploy/shadow-follow.sh deploys the shadow machine: in a
# throwaway folder, with fake psql and curl (what the main VPS runs and
# whether it's healthy), a fake deploy/shadow.sh (the deploys asked for)
# and a clock the test moves. No server, no Docker, no network.
#
#   deploy/shadow-follow-test.sh
set -euo pipefail
for var in $(compgen -e | grep -E '^(KT|KIT)_' || true); do unset "$var"; done
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

mkdir -p "$tmp/deploy" "$tmp/bin" "$tmp/.kamal"
cp "$here/shadow-follow.sh" "$tmp/deploy/"
touch "$tmp/.kamal/kit.local.env"

# The main VPS, as the fakes report it.
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
cat >"$tmp/bin/psql" <<'SH'
#!/usr/bin/env bash
[ "${DB_DOWN:-}" = true ] && exit 2
case "${*: -1}" in
  *collector_nodes*) printf '%s\n' "${LEADER:-}" ;;
  *alerts*) printf '%s\n' "${ALERTS:-0}" ;;
esac
SH
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  *healthz) [ "${SITE_DOWN:-}" != true ] ;;
  *health)
    [ "${INGRESS_DOWN:-}" != true ] || exit 22
    # -D FILE: the headers, as the ingress Worker adds them.
    for ((i = 1; i < $#; i++)); do
      [ "${!i}" = -D ] && { j=$((i + 1)); printf 'HTTP/2 200\r\nx-ingress-target: %s\r\n\r\n' "${TARGET:-main}" >"${!j}"; }
    done
    printf '{"ok":true,"rabbitmq":true,"spooled":0,"build":"%s"}' "${RECEIVERS:-}"
    ;;
esac
SH
cat >"$tmp/bin/fake-shadow" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
[ "${DEPLOY_FAILS:-}" != true ]
SH
chmod +x "$tmp/bin/"* "$tmp/deploy/shadow-follow.sh"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" \
  KT_FOLLOW_STATE="$tmp/state" KT_FOLLOW_NO_FETCH=true KT_FOLLOW_SHADOW_SH="$tmp/bin/fake-shadow" \
  KT_FOLLOW_MAIN_DB_URL=ecto://shadow_reader:pw@main.test:5432/kick_tracker \
  KT_FOLLOW_SITE_HEALTH=https://site.test/healthz KT_FOLLOW_INGRESS_HEALTH=https://ingress.test/health

t0=1790000000
# run MINUTES [ARGS]: one run at t0 + MINUTES, with the environment as set.
run() {
  local at=$1
  shift
  : >"$CALLS"
  KT_FOLLOW_NOW=$((t0 + at * 60)) "$tmp/deploy/shadow-follow.sh" "$@" >"$tmp/out" 2>&1 || true
}

# check NAME EXPECTED-CALLS (one per line, empty for none)
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

fresh() { rm -rf "$tmp/state"; unset DB_DOWN ALERTS SITE_DOWN INGRESS_DOWN DEPLOY_FAILS TARGET KT_SHADOW_SOAK; }

fresh
export LEADER=$A RECEIVERS=$A
run 0
check "a build first seen isn't deployed yet" ""
run 350
check "nor before 6 hours" ""
run 361
check "after 6 hours healthy, both groups get it" "--only shadow --version $A
--only backup-receiver --version $A"
run 371
check "and only once" ""

export LEADER=$B
run 400
check "a new collectors build starts its own clock" ""
run 761
check "and only the shadow gets it, 6 hours later" "--only shadow --version $B"

fresh
export LEADER=$A RECEIVERS=$A
run 0
export ALERTS=1
run 200
unset ALERTS
run 210
run 361
check "an open alert starts the clock again" ""
run 571
check "6 hours after it closed, it's deployed" "--only shadow --version $A
--only backup-receiver --version $A"

fresh
export LEADER=$A RECEIVERS=$A
for problem in DB_DOWN SITE_DOWN INGRESS_DOWN; do
  rm -rf "$tmp/state"
  run 0
  export "$problem=true"
  run 100
  unset "$problem"
  run 361
  check "$problem restarts the clock" ""
done

fresh
export LEADER=$A RECEIVERS=$A
run 0
export TARGET=backup
run 100
unset TARGET
run 361
check "the backup answering /health (the main receivers down) restarts the clock" ""

fresh
export LEADER="" RECEIVERS=$A
run 0
run 361
check "no leading collector: nothing deployed" ""

fresh
export LEADER=$A RECEIVERS=$A KT_SHADOW_SOAK=30m
run 0
run 31
check "KT_SHADOW_SOAK sets the wait" "--only shadow --version $A
--only backup-receiver --version $A"

fresh
export LEADER=$C RECEIVERS=$C ALERTS=3
run 0 --now
check "--now deploys the main VPS's builds at once, whatever the health" "--only shadow --version $C
--only backup-receiver --version $C"

fresh
export LEADER=$A RECEIVERS=$A
run 0 --pause
run 400
check "paused: nothing" ""
run 401 --resume
run 402
check "resumed: the clock runs from the next run" ""
run 763
check "and it deploys once due" "--only shadow --version $A
--only backup-receiver --version $A"

fresh
export LEADER=$A RECEIVERS=$A DEPLOY_FAILS=true
run 0
run 361
check "a failed deploy" "--only shadow --version $A
--only backup-receiver --version $A"
run 371
check "isn't tried again at once" ""
unset DEPLOY_FAILS
run 422
check "but an hour later" "--only shadow --version $A
--only backup-receiver --version $A"

fresh
export LEADER=$A RECEIVERS=$A
run 0 --status
check "--status deploys nothing" ""

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
