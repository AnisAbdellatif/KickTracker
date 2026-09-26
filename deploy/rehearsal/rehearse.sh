#!/usr/bin/env bash
# The deploy rehearsal (README.md here): the sandbox (`kit sandbox`,
# .kamal/sandbox/: the production stack on this machine, deployed by the
# kit and Kamal as production is), kept busy (a visitor on the site every
# second, webhooks every few seconds, three live channels with chat) and
# upgraded the way production is upgraded, measuring what each step costs:
#
#   web deploy (with a migration on a live hypertable), collector deploy,
#   receiver deploy, database restart, RabbitMQ restart, a collector
#   killed, a rollback of web and collectors, and a whole release.
#
#   deploy/rehearsal/rehearse.sh         # all of it, then a report
#   deploy/rehearsal/rehearse.sh report  # the report again, from the running sandbox
#   deploy/rehearsal/rehearse.sh down    # remove the sandbox and its data
#
# It starts from a fresh sandbox: one already running is reset, its data
# with it. At the end the sandbox keeps running, to look around in
# (`kit sandbox status`); `down` removes it. Needs Docker and Elixir (for
# the fake Kick). Takes about 30 minutes, mostly waiting for polls to
# happen. Writes its logs and the report under deploy/rehearsal/.work
# (git-ignored).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
WORK=${REHEARSAL_DIR:-$REPO/deploy/rehearsal/.work}
LOG=$WORK/log
KIT=$REPO/.kamal/kit/bin/kit
SANDBOX_WORK=$REPO/.kamal/sandbox/.work
export COMPOSE_PROJECT_NAME=kicktracker-sandbox

REGISTRY=127.0.0.1:5555
APP=$REGISTRY/anisabdellatif/kicktracker-app
RECEIVER=$REGISTRY/anisabdellatif/kicktracker-receiver
V1="" # the sandbox's first deploy (sandbox-1), read after `kit sandbox up`
V2=rehearsal-v2
SIM=http://127.0.0.1:4050
SITE=http://localhost:8080
CHANNELS=$(grep -o 'slug: "[^"]*"' .kamal/sandbox/scenario.exs | cut -d'"' -f2 | tr '\n' ' ')

# dc ARGS...: compose, for the sandbox's stack (the database, RabbitMQ, Caddy).
dc() { (cd "$SANDBOX_WORK/server" && docker compose -f compose.single.yml -f compose.sandbox.yml "$@"); }

# kitd ARGS...: the kit, aimed at the sandbox (which first checks, every
# time, that Kamal would deploy only to this machine).
kitd() { "$KIT" sandbox kit "$@"; }

# role_container ROLE: the running container of a Kamal role.
role_container() {
  docker ps -q --filter "label=role=$1" --filter label=destination=sandbox | head -1
}

say() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG/steps.log"; }
now() { date -u +%s; }
psql_q() { dc exec -T db psql -U kick_tracker -d kick_tracker -Atc "$1"; }

# --- the sandbox, and a second build -----------------------------------------------

up() {
  say "a fresh sandbox: reset, then up (the working tree built, the stack and the fake Kick started, everything deployed, the channels tracked)"
  "$KIT" sandbox reset --yes
  "$KIT" sandbox up
  V1="sandbox-$(cat "$SANDBOX_WORK/version")"

  # v2: v1 plus a migration on a hypertable the collectors write to all
  # the time (expand only: a nullable column), to see what a migration
  # under load costs. The receiver's v2 is v1 under another tag: the
  # containers are still replaced.
  say "building $V2: $V1 plus a migration on viewer_samples"
  local ctx=$WORK/v2
  rm -rf "$ctx" && mkdir -p "$ctx"
  cat > "$ctx/20990101000000_rehearsal_probe.exs" <<'EOS'
defmodule KickTracker.Repo.Migrations.RehearsalProbe do
  use Ecto.Migration

  def change do
    alter table(:viewer_samples) do
      add :rehearsal_probe, :integer
    end
  end
end
EOS
  cat > "$ctx/Dockerfile" <<EOS
FROM $APP:$V1
COPY --chown=app 20990101000000_rehearsal_probe.exs /app/lib/kick_tracker-0.1.0/priv/repo/migrations/
EOS
  docker build -q -t "$APP:$V2" --label service=kicktracker "$ctx" >/dev/null
  docker tag "$RECEIVER:$V1" "$RECEIVER:$V2"
  docker push -q "$APP:$V2" >/dev/null
  docker push -q "$RECEIVER:$V2" >/dev/null

  # Through Caddy, as visitors and Kick reach it: nothing else counts.
  say "checking the site answers through Caddy"
  local code=""
  for _ in $(seq 1 30); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$SITE/healthz" || true)
    [ "$code" = 200 ] && break
    sleep 2
  done
  if [ "$code" != 200 ]; then
    say "the site doesn't answer through Caddy (HTTP $code): stopping"
    exit 1
  fi
  echo "$V1" > "$WORK/v1"
}

# --- load and probes ---------------------------------------------------------------

probes() {
  # A page a second: under the site's limit of 120 a minute per address.
  say "starting probes: the home page every second, a gift webhook every 3s"
  (while true; do
     code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$SITE/" || true)
     echo "$(date +%s.%N | cut -c1-14) $code"
     sleep 1
   done) > "$LOG/site.log" 2>/dev/null &
  echo $! > "$WORK/site.pid"
  (while true; do
     for c in $CHANNELS; do
       curl -s -o /dev/null -X POST -H 'content-type: application/json' \
         -d '{"type":"gift"}' "$SIM/_sim/channels/$c/events" || true
     done
     sleep 3
   done) > /dev/null 2>&1 &
  echo $! > "$WORK/events.pid"
}

stop_probes() {
  for p in site events; do
    [ -f "$WORK/$p.pid" ] && kill "$(cat "$WORK/$p.pid")" 2>/dev/null || true
  done
}

# --- the operations ----------------------------------------------------------------

op() {
  local name=$1
  shift
  say "== $name"
  echo "$name $(now)" >> "$LOG/ops.start"
  if ! "$@" >> "$LOG/ops.log" 2>&1; then
    say "   (it failed: see $LOG/ops.log)"
    echo "$name" >> "$LOG/ops.failed"
  fi
  # Settle: the infrastructure healthy again, and a poll cycle after.
  dc up -d --wait --no-recreate >> "$LOG/ops.log" 2>&1 || true
  sleep 75
  echo "$name $(now)" >> "$LOG/ops.end"
}

leader_container() {
  local r id
  for r in collector_a collector_b; do
    id=$(role_container "$r")
    if [ -n "$id" ] && docker exec "$id" curl -fsS http://127.0.0.1:4101/status 2>/dev/null | grep -q '"role":"leader"'; then
      echo "$id"
      return
    fi
  done
}

# The collecting container killed, as a crash would. Docker counts `docker
# kill` as stopping it by hand and skips its restart policy (a real crash
# is restarted): start it again as the policy would, a few seconds later.
kill_leader() {
  local id
  id=$(leader_container)
  docker kill -s KILL "$id"
  sleep 3
  docker start "$id"
}

# A whole release as `deploy/release.sh --all` does it (both Kamal configs,
# every group), with the smoke tests through Caddy that would roll it back
# (KIT_SMOKE_URLS_SANDBOX).
release() {
  kitd deploy -c deploy/kamal/app.yml --version "$1"
  kitd deploy -c deploy/kamal/receiver.yml --version "$1"
}

operations() {
  say "baseline: two minutes of normal running"
  echo "baseline $(now)" >> "$LOG/ops.start"
  sleep 120
  echo "baseline $(now)" >> "$LOG/ops.end"

  op "web deploy (with a migration on viewer_samples)" kitd group deploy web -- --version "$V2"
  op "collector deploy" kitd group deploy collectors -- --version "$V2"
  op "receiver deploy" kitd group deploy receivers -- --version "$V2"
  op "database restart" dc restart db
  op "RabbitMQ restart" dc restart rabbitmq
  op "collector killed (SIGKILL)" kill_leader
  op "rollback: web" kitd group deploy web -- --version "$V1"
  # After the kill the other collector (still on v1) collects: this hands
  # collection back and forth, the collectors' rollback, nothing pulled.
  op "collectors switched (the rollback: a handover, nothing pulled)" kitd group switch collectors
  op "release (kit deploy, both configs) to v2" release "$V2"
}

# --- the report ----------------------------------------------------------------------

report() {
  local out=$WORK/report.md
  say "writing the report to $out"

  # Webhooks: every delivery the fake Kick made (not dropped on purpose)
  # against what reached the database. Deliveries still in flight when the
  # list is taken (the probe keeps sending) get up to 30s to land.
  curl -s "$SIM/_sim/webhooks" | python3 -c '
import json, sys
print("\n".join(json.load(sys.stdin)["message_ids"]))' | sort -u > "$LOG/sent.txt"
  local missing waited=0
  while :; do
    psql_q "SELECT message_id FROM webhook_events" | sort -u > "$LOG/stored.txt"
    missing=$(comm -23 "$LOG/sent.txt" "$LOG/stored.txt" | wc -l)
    if [ "$missing" -eq 0 ] || [ "$waited" -ge 30 ]; then break; fi
    sleep 1
    waited=$((waited + 1))
  done

  {
    echo "# Deploy rehearsal"
    echo
    echo "Run $(date -u +%Y-%m-%dT%H:%MZ) with images $APP:$V1 / $V2, deployed to the sandbox with deploy-kit $(cat "$REPO/.kamal/kit/VERSION") and Kamal."
    echo
    if [ -s "$LOG/ops.failed" ]; then
      echo "**Operations that failed:** $(tr '\n' ';' < "$LOG/ops.failed")"
    else
      echo "Every operation succeeded."
    fi
    echo
    echo "## The site during each operation"
    echo
    echo "The home page every second through Caddy; failed is no answer, a 5xx or a 429."
    echo
    echo "| Operation | Requests | Failed | Longest outage |"
    echo "|---|---|---|---|"
    paste -d' ' <(cut -d' ' -f1- "$LOG/ops.start") <(awk '{print $NF}' "$LOG/ops.end") | while read -r line; do
      local end start name
      end=${line##* }
      line=${line% *}
      start=${line##* }
      name=${line% *}
      python3 - "$LOG/site.log" "$start" "$end" "$name" <<'PY'
import sys
path, start, end, name = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
rows = []
for l in open(path):
    parts = l.split()
    if len(parts) == 2:
        t, code = float(parts[0]), parts[1]
        if start <= t <= end:
            rows.append((t, code in ("000", "429") or code.startswith("5")))
failed = sum(1 for _, f in rows if f)
longest, run_start = 0.0, None
for t, f in rows:
    if f and run_start is None:
        run_start = t
    if not f and run_start is not None:
        longest, run_start = max(longest, t - run_start), None
if run_start is not None:
    longest = max(longest, rows[-1][0] - run_start)
print(f"| {name} | {len(rows)} | {failed} | {longest:.1f}s |")
PY
    done
    echo
    echo "## Collection"
    echo
    echo "Viewer readings per channel per minute, across the whole run (one per minute expected; 0 is a gap):"
    echo
    echo '```'
    # Minutes as epoch minutes, so a run across midnight counts right.
    psql_q "SELECT c.slug, floor(extract(epoch FROM v.observed_at) / 60)::bigint, count(*)
            FROM viewer_samples v JOIN channels c ON c.id = v.channel_id
            GROUP BY 1, 2 ORDER BY 1, 2" |
      python3 -c '
import sys, collections, time
rows = collections.defaultdict(dict)
for l in sys.stdin:
    slug, minute, n = l.strip().split("|")
    rows[slug][int(minute)] = int(n)
for slug, minutes in rows.items():
    keys = sorted(minutes)
    gaps = [time.strftime("%H:%M", time.gmtime(m * 60)) for m in range(keys[0], keys[-1] + 1) if m not in minutes]
    print(slug + ": " + str(len(keys)) + " minutes with readings, gaps: " + (", ".join(gaps) or "none"))'
    echo '```'
    echo
    echo "Chat minutes per channel: $(psql_q "SELECT string_agg(slug || ' ' || n, ', ') FROM (SELECT c.slug, count(*) n FROM chat_minutes m JOIN channels c ON c.id = m.channel_id GROUP BY 1) x")"
    echo
    echo "Who collected when (collector_terms):"
    echo
    echo '```'
    psql_q "SELECT epoch, holder, to_char(started_at, 'HH24:MI:SS.MS'), coalesce(to_char(ended_at, 'HH24:MI:SS.MS'), 'now'), coalesce(end_reason, '') FROM collector_terms ORDER BY epoch"
    echo '```'
    echo
    echo "Collectors' journals now: $(psql_q "SELECT string_agg(id || ' ' || state || ' depth ' || (status->'journal'->>'depth') || ' buried ' || (status->'journal'->>'buried'), '; ') FROM collector_nodes")"
    echo
    echo "## Webhooks"
    echo
    echo "Delivered by the fake Kick: $(wc -l < "$LOG/sent.txt"); stored: $(wc -l < "$LOG/stored.txt"); **missing: $missing**."
    echo
    echo "## Cluster and alerts"
    echo
    echo "web_a sees: $(docker exec "$(role_container web_a)" bin/kick_tracker rpc 'IO.puts(Enum.join(Node.list(), " "))' | tr -d '\r')"
    echo
    echo "Running at the end:"
    echo
    echo '```'
    docker ps --filter label=destination=sandbox --format '{{.Names}}  {{.Status}}' | sort
    echo '```'
    echo
    echo "Open alerts: $(psql_q "SELECT coalesce(string_agg(message, '; '), 'none') FROM alerts WHERE resolved_at IS NULL")"
    echo
    echo "Migration applied: $(psql_q "SELECT count(*) FROM information_schema.columns WHERE table_name = 'viewer_samples' AND column_name = 'rehearsal_probe'") (1 = the v2 migration ran)"
  } > "$out"
  cat "$out"
}

down() {
  stop_probes
  "$KIT" sandbox reset --yes
}

case "${1:-all}" in
  all)
    mkdir -p "$WORK"
    stop_probes
    rm -rf "$LOG" && mkdir -p "$LOG"
    up
    probes
    trap 'stop_probes' EXIT
    operations
    stop_probes
    report
    ;;
  report)
    V1=$(cat "$WORK/v1" 2>/dev/null || echo "sandbox-1")
    report
    ;;
  down) down ;;
  *) echo "usage: $0 [all|report|down]" >&2; exit 1 ;;
esac
