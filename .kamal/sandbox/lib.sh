# shellcheck shell=bash
# Shared by the sandbox's hooks (README.md here): the infrastructure Kamal
# doesn't run, as production runs it (deploy/compose.single.yml: the
# database, RabbitMQ, Caddy), and the fake Kick (sim/) in place of kick.com.
#
# The "server's checkout" is KIT_SANDBOX_SERVER_DIR, mounted on the sandbox
# server at /srv/kick_tracker/deploy (KIT_SANDBOX_SERVER_PATH): a copy of
# deploy/ with generated local secrets, where compose runs and where the
# roles' env files (deploy/kamal/*.yml) and the migrate step look.

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO=$PWD
SERVER_DIR=${KIT_SANDBOX_SERVER_DIR:?run by kit sandbox}
WORK=${KIT_SANDBOX_WORK:?run by kit sandbox}
export COMPOSE_PROJECT_NAME=kicktracker-sandbox
export DB_IMAGE=kicktracker-db:sandbox # the database image compose runs (.env)
SIM=http://127.0.0.1:4050
# The fake Kick's channels (their slugs are what seed tracks).
SCENARIO=${KT_SANDBOX_SCENARIO:-$REPO/.kamal/sandbox/scenario.exs}

# dc ARGS...: compose, for the sandbox's stack.
dc() { (cd "$SERVER_DIR" && docker compose -f compose.single.yml -f compose.sandbox.yml "$@"); }

# sync_deploy: deploy/ copied to the server's checkout again (compose files,
# Caddy's config, scripts), leaving the generated files alone.
sync_deploy() {
  mkdir -p "$SERVER_DIR"
  (cd "$REPO/deploy" && tar --exclude=./rehearsal/.work --exclude='./secrets/*.env' --exclude=./.env \
    --exclude=./rabbitmq/definitions.prod.json -cf - .) | (cd "$SERVER_DIR" && tar -xf -)
}

sim_running() {
  [ -f "$WORK/sim.pid" ] && kill -0 "$(cat "$WORK/sim.pid")" 2>/dev/null && curl -sf -o /dev/null "$SIM/_sim/state"
}

# start_sim: the fake Kick on :4050, delivering webhooks through Caddy to
# the ingress; detached, so it outlives the hook.
start_sim() {
  sim_running && return 0
  echo "starting the fake Kick on :4050 ($(basename "$SCENARIO"); the first start compiles it)"
  [ -d "$REPO/sim/deps" ] || (cd "$REPO/sim" && mix deps.get >/dev/null)
  (cd "$REPO/sim" && exec nohup setsid mix sim --ip 0.0.0.0 --port 4050 --scenario "$SCENARIO" \
    --webhook-url http://127.0.0.1:8080/ --asset-url http://host.docker.internal:4050) >"$WORK/sim.log" 2>&1 </dev/null &
  echo $! >"$WORK/sim.pid"
  local waited=0
  until curl -sf -o /dev/null "$SIM/_sim/state"; do
    kill -0 "$(cat "$WORK/sim.pid")" 2>/dev/null || { echo "the fake Kick stopped: $WORK/sim.log" >&2 && return 1; }
    [ "$waited" -lt 300 ] || { echo "the fake Kick didn't answer in 5 minutes: $WORK/sim.log" >&2 && return 1; }
    sleep 1
    waited=$((waited + 1))
  done
}

stop_sim() {
  [ -f "$WORK/sim.pid" ] && kill -- "-$(cat "$WORK/sim.pid")" 2>/dev/null
  [ -f "$WORK/sim.pid" ] && kill "$(cat "$WORK/sim.pid")" 2>/dev/null
  rm -f "$WORK/sim.pid"
  return 0
}

# site_settings: what the site needs to be served on this machine, none of
# it secret, so applied on every `up` too (a sandbox made before a change
# here gets it without a reset): Caddy's hosts and /admin allowlist, the
# public URL the app builds links with (invitations: http://localhost:8080),
# and the admin signing in by itself (web nodes only; the app refuses it
# unless PHX_HOST is localhost, and lets in only requests for localhost).
site_settings() {
  local secrets=$SERVER_DIR/secrets file
  # Plain HTTP on 127.0.0.1:8080 (compose.sandbox.yml): the site on
  # localhost, the ingress on 127.0.0.1. Through Docker's port forwarding a
  # browser here arrives from a Docker network's gateway, not 127.0.0.1:
  # Docker's private ranges are allowed on /admin (Caddy listens on
  # 127.0.0.1 only, so nothing outside this machine reaches it).
  printf 'SITE_HOST=http://localhost\nINGRESS_HOST=http://127.0.0.1\nACME_EMAIL=ops@example.org\nADMIN_ALLOW=127.0.0.1/32 172.16.0.0/12 192.168.0.0/16\n' \
    >"$secrets/stack.env"
  for file in "$secrets/app.env" "$secrets/collector.env"; do
    set_env "$file" PHX_URL_SCHEME http
    set_env "$file" PHX_URL_PORT 8080
  done
  set_env "$secrets/app.env" ADMIN_AUTOLOGIN admin@sandbox.localhost
}

# set_env FILE NAME VALUE: NAME=VALUE in an env file, replaced or added.
set_env() {
  if grep -q "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >>"$1"
  fi
}

# The channels the fake Kick runs, from the scenario.
channels() { grep -o 'slug: "[^"]*"' "$SCENARIO" | cut -d'"' -f2 | tr '\n' ' '; }

# The Kick this sandbox talks to: "fake" (sim/, the default) or "real",
# only when the owner opts in with KT_SANDBOX_KICK=real and kick.env (the
# sandbox's own Kick app; README.md here). Chosen when the sandbox is
# created and kept: changing it needs `kit sandbox reset`.
KICK_ENV=$REPO/.kamal/sandbox/kick.env
kick_mode() {
  local had=""
  [ -f "$WORK/kick-mode" ] && had=$(cat "$WORK/kick-mode")
  # A sandbox made before the choice existed talks to the fake one.
  [ -z "$had" ] && [ -f "$SERVER_DIR/secrets/app.env" ] && had=fake
  if [ -n "$had" ]; then
    if [ -n "${KT_SANDBOX_KICK:-}" ] && [ "$KT_SANDBOX_KICK" != "$had" ]; then
      echo "this sandbox talks to the $had Kick; KT_SANDBOX_KICK=$KT_SANDBOX_KICK needs a new one (kit sandbox reset first)" >&2
      return 1
    fi
    echo "$had"
    return 0
  fi
  case ${KT_SANDBOX_KICK:-fake} in
    fake | real) echo "${KT_SANDBOX_KICK:-fake}" ;;
    *) echo "KT_SANDBOX_KICK is fake or real, not '$KT_SANDBOX_KICK'" >&2 && return 1 ;;
  esac
}

# load_kick_env: kick.env's settings, checked: filled in, and not
# production's Kick app (whose subscriptions the sandbox would rewrite).
load_kick_env() {
  [ -f "$KICK_ENV" ] || { echo "KT_SANDBOX_KICK=real needs $KICK_ENV (from kick.env.example)" >&2 && return 1; }
  set -a
  # shellcheck source=/dev/null
  . "$KICK_ENV"
  set +a
  local var
  for var in KICK_API_URL KICK_ID_URL KICK_V2_URL PUSHER_URL KICK_CLIENT_ID KICK_CLIENT_SECRET; do
    case ${!var:-CHANGE_ME} in *CHANGE_ME*) echo "$KICK_ENV: $var isn't filled in" >&2 && return 1 ;; esac
  done
  local production=""
  production=$("$REPO/.kamal/kit/bin/kit" sops get "$REPO/deploy/secrets/collector.sops.env" KICK_CLIENT_ID 2>/dev/null) ||
    echo "(couldn't read production's Kick client id to compare: no sops key here? Make sure kick.env is the sandbox's own app.)" >&2
  if [ -n "$production" ] && [ "$production" = "$KICK_CLIENT_ID" ]; then
    echo "$KICK_ENV holds production's Kick app: the sandbox needs its own (its subscription sync would remove production's webhooks)" >&2
    return 1
  fi
}
