#!/usr/bin/env bash
# The deploy rehearsal (README.md here): runs the production stack
# (compose.single.yml) on this machine against the fake Kick, keeps it
# busy (a visitor on the site every second, webhooks every few seconds,
# three live channels with chat), and upgrades it the way production is
# upgraded, through deploy.sh, measuring what each step costs:
#
#   web deploy (with a migration on a live hypertable), collector deploy,
#   receiver deploy, database restart, RabbitMQ restart, a collector
#   killed, and a rollback to the previous image.
#
#   deploy/rehearsal/rehearse.sh         # all of it, then a report
#   deploy/rehearsal/rehearse.sh down    # remove the stack and its volumes
#
# Needs Docker (compose v2.24+) and Elixir (for the fake Kick). Takes
# about 25 minutes, mostly waiting for polls to happen. Writes everything
# under deploy/rehearsal/.work (git-ignored), the report included.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${REHEARSAL_DIR:-$REPO/deploy/rehearsal/.work}
DEPLOY=$WORK/deploy
LOG=$WORK/log
export COMPOSE_PROJECT_NAME=kicktracker-rehearsal
export COMPOSE_FILES="compose.single.yml compose.rehearsal.yml"

APP_V1=kicktracker-app:rehearsal-v1
APP_V2=kicktracker-app:rehearsal-v2
RECEIVER_V1=kicktracker-receiver:rehearsal-v1
RECEIVER_V2=kicktracker-receiver:rehearsal-v2
DB_IMAGE=kicktracker-db:rehearsal
SIM=http://127.0.0.1:4050
SITE=http://localhost:8080
CHANNELS="rehearsalbig rehearsalmid rehearsalsmall"

dc() {
  local args=()
  for f in $COMPOSE_FILES; do args+=(-f "$f"); done
  (cd "$DEPLOY" && docker compose "${args[@]}" "$@")
}

say() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG/steps.log"; }
now() { date -u +%s; }
rand() { head -c 256 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }
psql_q() { dc exec -T db psql -U kick_tracker -d kick_tracker -Atc "$1"; }

# --- images -------------------------------------------------------------------

build() {
  say "building images (cached layers make this quick after the first time)"
  docker build -q -t "$APP_V1" -f "$REPO/app/Dockerfile" "$REPO/app" >/dev/null
  docker build -q -t "$RECEIVER_V1" -f "$REPO/ingress/receiver/Dockerfile" "$REPO/ingress/receiver" >/dev/null
  docker build -q -t "$DB_IMAGE" -f "$REPO/deploy/db/Dockerfile" "$REPO/deploy/db" >/dev/null

  # v2: v1 plus a migration on a hypertable the collectors write to all
  # the time (expand only: a nullable column), to see what a migration
  # under load costs. The receiver's v2 is v1 under another tag: the
  # containers are still replaced.
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
FROM $APP_V1
COPY --chown=app 20990101000000_rehearsal_probe.exs /app/lib/kick_tracker-0.1.0/priv/repo/migrations/
EOS
  docker build -q -t "$APP_V2" "$ctx" >/dev/null
  docker tag "$RECEIVER_V1" "$RECEIVER_V2"
}

# --- the stack ------------------------------------------------------------------

setup() {
  say "writing a working copy of deploy/ with local secrets in $DEPLOY"
  rm -rf "$DEPLOY" && mkdir -p "$DEPLOY" "$LOG"
  (cd "$REPO/deploy" && tar --exclude=rehearsal/.work -cf - .) | (cd "$DEPLOY" && tar -xf -)
  cp "$REPO/deploy/rehearsal/compose.rehearsal.yml" "$DEPLOY/"

  local db_pw app_pw receiver_pw ops_pw monitor_pw admin_pw cookie
  db_pw=$(rand) app_pw=$(rand) receiver_pw=$(rand) ops_pw=$(rand) monitor_pw=$(rand) admin_pw=$(rand)
  cookie=$(rand 48)
  local kick="KICK_API_URL=http://host.docker.internal:4050
KICK_ID_URL=http://host.docker.internal:4050
KICK_V2_URL=http://host.docker.internal:4050/api/v2
PUSHER_URL=ws://host.docker.internal:4050/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false
KICK_CLIENT_ID=rehearsal
KICK_CLIENT_SECRET=rehearsal"
  local common="DATABASE_URL=ecto://kick_tracker:$db_pw@db/kick_tracker
POOL_SIZE=10
DNS_CLUSTER_QUERY=app
RELEASE_COOKIE=$cookie
SITE_NAME=Stream Tracker
PHX_HOST=localhost
CONTACT_EMAIL=ops@example.org
$kick
AMQP_URL=amqp://app:$app_pw@rabbitmq:5672
DEAD_LETTERS_AMQP_URL=amqp://ops:$ops_pw@rabbitmq:5672
RABBITMQ_MANAGEMENT_URL=http://monitor:$monitor_pw@rabbitmq:15672"

  mkdir -p "$DEPLOY/secrets"
  printf '%s\nSECRET_KEY_BASE=%s\n' "$common" "$(rand 64)" > "$DEPLOY/secrets/app.env"
  printf '%s\n' "$common" > "$DEPLOY/secrets/collector.env"
  printf 'PORT=4060\nAMQP_URL=amqp://receiver:%s@rabbitmq:5672\nKICK_API_URL=http://host.docker.internal:4050\n' \
    "$receiver_pw" > "$DEPLOY/secrets/receiver.env"
  printf 'POSTGRES_USER=kick_tracker\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=kick_tracker\nWALG_FILE_PREFIX=/var/lib/postgresql/walg-store\nWALG_COMPRESSION_METHOD=zstd\n' \
    "$db_pw" > "$DEPLOY/secrets/db.env"
  # Plain HTTP on 127.0.0.1:8080: the site on localhost, the ingress on 127.0.0.1.
  printf 'SITE_HOST=http://localhost\nINGRESS_HOST=http://127.0.0.1\nACME_EMAIL=ops@example.org\nADMIN_ALLOW=127.0.0.1/32\n' \
    > "$DEPLOY/secrets/stack.env"

  RABBITMQ_ADMIN_PASSWORD=$admin_pw RABBITMQ_RECEIVER_PASSWORD=$receiver_pw RABBITMQ_APP_PASSWORD=$app_pw \
    RABBITMQ_OPS_PASSWORD=$ops_pw RABBITMQ_MONITOR_PASSWORD=$monitor_pw "$DEPLOY/rabbitmq/make-prod-definitions.sh"

  printf 'APP_IMAGE=%s\nCOLLECTOR_IMAGE=%s\nRECEIVER_IMAGE=%s\nDB_IMAGE=%s\n' \
    "$APP_V1" "$APP_V1" "$RECEIVER_V1" "$DB_IMAGE" > "$DEPLOY/.env"
}

start_sim() {
  say "starting the fake Kick on :4050 (webhooks to the stack's ingress)"
  (cd "$REPO/sim" && exec mix sim --ip 0.0.0.0 --port 4050 \
    --scenario "$REPO/deploy/rehearsal/scenario.exs" --webhook-url http://127.0.0.1:8080/) \
    > "$LOG/sim.log" 2>&1 &
  echo $! > "$WORK/sim.pid"
  until curl -sf "$SIM/_sim/state" >/dev/null; do sleep 1; done
}

up() {
  say "starting the stack: database and queue, migrations, then everything"
  dc up -d --wait db rabbitmq
  dc run --rm migrate
  dc up -d --wait
  # Through Caddy, as visitors and Kick reach it: nothing else counts.
  say "checking the site and the ingress answer through Caddy"
  for _ in $(seq 1 30); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$SITE/healthz" || true)
    [ "$code" = 200 ] && break
    sleep 2
  done
  if [ "$code" != 200 ]; then
    say "the site doesn't answer through Caddy (HTTP $code): stopping"
    exit 1
  fi
  say "tracking $CHANNELS"
  dc exec -T web-a bin/kick_tracker rpc "
    for slug <- ~w($CHANNELS), do: IO.inspect(KickTracker.Channels.add(slug) |> elem(0), label: slug)
    IO.inspect(Node.list(), label: \"cluster\")"
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
  "$@" >> "$LOG/ops.log" 2>&1
  # Settle: healthy again, and a poll cycle after.
  dc up -d --wait --no-recreate >> "$LOG/ops.log" 2>&1 || true
  sleep 75
  echo "$name $(now)" >> "$LOG/ops.end"
}

deploy() { (cd "$DEPLOY" && ROLE=$1 APP_IMAGE=${2:-} RECEIVER_IMAGE=${3:-} ./deploy.sh); }

leader_container() {
  for c in collector-a collector-b; do
    if dc exec -T "$c" curl -fsS http://127.0.0.1:4101/status 2>/dev/null | grep -q '"role":"leader"'; then
      dc ps -q "$c"
      return
    fi
  done
}

kill_leader() {
  local id
  id=$(leader_container)
  docker kill -s KILL "$id"
}

operations() {
  say "baseline: two minutes of normal running"
  echo "baseline $(now)" >> "$LOG/ops.start"
  sleep 120
  echo "baseline $(now)" >> "$LOG/ops.end"

  op "web deploy (with a migration on viewer_samples)" deploy web "$APP_V2"
  op "collector deploy" deploy collector "$APP_V2"
  op "receiver deploy" deploy receivers "" "$RECEIVER_V2"
  op "database restart" dc restart db
  op "RabbitMQ restart" dc restart rabbitmq
  op "collector killed (SIGKILL)" kill_leader
  op "rollback: web" deploy web "$APP_V1"
  op "rollback: collectors (switch to the standby, still on v1)" deploy collector-switch
}

# --- the report ----------------------------------------------------------------------

report() {
  local out=$WORK/report.md
  say "writing the report to $out"

  # Webhooks: every delivery the fake Kick made (not dropped on purpose)
  # against what reached the database. The last 30s are left out (in flight).
  curl -s "$SIM/_sim/webhooks" | python3 -c '
import json, sys
print("\n".join(json.load(sys.stdin)["message_ids"]))' | sort -u > "$LOG/sent.txt"
  psql_q "SELECT message_id FROM webhook_events" | sort -u > "$LOG/stored.txt"
  local missing
  missing=$(comm -23 "$LOG/sent.txt" "$LOG/stored.txt" | wc -l)

  {
    echo "# Deploy rehearsal"
    echo
    echo "Run $(date -u +%Y-%m-%dT%H:%MZ) with images $APP_V1 / $APP_V2."
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
    psql_q "SELECT c.slug, to_char(date_trunc('minute', v.observed_at), 'HH24:MI'), count(*)
            FROM viewer_samples v JOIN channels c ON c.id = v.channel_id
            GROUP BY 1, 2 ORDER BY 1, 2" |
      python3 -c '
import sys, collections
rows = collections.defaultdict(dict)
for l in sys.stdin:
    slug, minute, n = l.strip().split("|")
    rows[slug][minute] = int(n)
for slug, minutes in rows.items():
    keys = sorted(minutes)
    h0, m0 = map(int, keys[0].split(":")); h1, m1 = map(int, keys[-1].split(":"))
    all_minutes = [f"{(m // 60) % 24:02d}:{m % 60:02d}" for m in range(h0 * 60 + m0, h1 * 60 + m1 + 1)]
    gaps = [m for m in all_minutes if m not in minutes]
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
    echo "web-a sees: $(dc exec -T web-a bin/kick_tracker rpc 'IO.puts(Enum.join(Node.list(), " "))' | tr -d '\r')"
    echo
    echo "Open alerts: $(psql_q "SELECT coalesce(string_agg(message, '; '), 'none') FROM alerts WHERE resolved_at IS NULL")"
    echo
    echo "Migration applied: $(psql_q "SELECT count(*) FROM information_schema.columns WHERE table_name = 'viewer_samples' AND column_name = 'rehearsal_probe'") (1 = the v2 migration ran)"
  } > "$out"
  cat "$out"
}

down() {
  stop_probes
  [ -f "$WORK/sim.pid" ] && kill "$(cat "$WORK/sim.pid")" 2>/dev/null || true
  pkill -f "mix sim --ip 0.0.0.0 --port 4050" 2>/dev/null || true
  [ -d "$DEPLOY" ] && dc down -v --remove-orphans || true
}

case "${1:-all}" in
  all)
    mkdir -p "$WORK" "$LOG"
    down
    rm -rf "$LOG" && mkdir -p "$LOG"
    build
    setup
    start_sim
    up
    probes
    trap 'stop_probes' EXIT
    operations
    stop_probes
    report
    ;;
  report) report ;;
  down) down ;;
  *) echo "usage: $0 [all|report|down]" >&2; exit 1 ;;
esac
