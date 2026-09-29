# shellcheck shell=bash
# Groups: roles deployed together by a strategy instead of all at once.
# Sourced after core.sh, notify.sh and kamal.sh. docs/groups.md explains
# them; this is the engine.
#
# A group is a folder, .kamal/groups/<name>/, holding group.env and,
# optionally, scripts the strategy calls:
#
#   active     exit 0 if $KIT_ROLE is the active one (standby: required)
#   healthy    exit 0 if $KIT_ROLE is healthy (default: its container runs)
#   handover   make $KIT_TO active instead of $KIT_FROM (default: restart
#              $KIT_FROM in place on its own build; its clean stop hands over)
#   before, after              around the whole group deploy
#   before-role, after-role    around each role's deploy ($KIT_ROLE)
#
# Instead of a script, group.env may set KIT_GROUP_<SCRIPT>_CMD to a shell
# one-liner (KIT_GROUP_ACTIVE_CMD, KIT_GROUP_BEFORE_ROLE_CMD…).
#
# Strategies:
#   standby   two roles, one active. A deploy updates the standby only,
#             waits until it's healthy, then hands over; the old active
#             stays on the previous build as the new standby, so rolling
#             back is handing back (`kit group switch`).
#   rolling   any number of roles (alias: pair), updated one at a time,
#             each healthy before the next; the rest keep serving.
#
# Each group runs in its own `kit` process, so one group's settings never
# leak into another's.

# kit_group_dir NAME
kit_group_dir() { printf '%s/groups/%s\n' "$KIT_CONFIG_DIR" "$1"; }

# kit_group_names_all: every group, in KIT_GROUP_ORDER, then the rest
# alphabetically, whatever Kamal config it belongs to.
kit_group_names_all() {
  local dir name order seen=""
  order=$(kit_conf KIT_GROUP_ORDER "")
  for name in $(kit_words "$order"); do
    [ -f "$(kit_group_dir "$name")/group.env" ] || kit_die "KIT_GROUP_ORDER names '$name', which has no .kamal/groups/$name/group.env"
    printf '%s\n' "$name"
    seen="$seen $name"
  done
  for dir in "$KIT_CONFIG_DIR"/groups/*/; do
    [ -f "$dir/group.env" ] || continue
    name=$(basename "$dir")
    kit_in_list "$name" "$seen" || printf '%s\n' "$name"
  done
}

# kit_group_names: the groups of the Kamal config in use (KIT_KAMAL_CONFIG_FILE,
# -c). A group belongs to the config named by KIT_GROUP_KAMAL_CONFIG_FILE in
# its group.env; when unset, to the project's config (KIT_KAMAL_CONFIG_FILE
# in .kamal/kit.env, else Kamal's config/deploy.yml). A project with
# several Kamal configs (one per image, say) has groups for each.
kit_group_names() {
  local current name all
  current=$(kit_config_file "$(kit_conf KIT_KAMAL_CONFIG_FILE "")")
  # Read first: a stop within $(...) in a for list would go unnoticed.
  all=$(kit_group_names_all) || return 1
  local file
  for name in $all; do
    file=$(kit_group_config_file "$name") || return 1
    [ "$file" = "$current" ] && printf '%s\n' "$name"
  done
  return 0
}

# kit_config_file [FILE]: a Kamal config path as the kit compares them
# (empty means Kamal's default, config/deploy.yml; a leading ./ dropped).
kit_config_file() {
  local file=${1:-config/deploy.yml}
  printf '%s\n' "${file#./}"
}

# kit_group_config_file NAME: the Kamal config the group belongs to.
# Fails when group.env can't be read: taken for the project's, a group of
# another config would go unguarded there.
kit_group_config_file() {
  local file
  file=$(kit_group_setting "$1" KIT_GROUP_KAMAL_CONFIG_FILE) || return 1
  kit_config_file "${file:-${KIT_PROJECT_KAMAL_CONFIG_FILE:-}}"
}

# kit_config_service FILE [DESTINATION]: the `service:` a Kamal config names,
# the destination's file (config/deploy.DEST.yml) over it as Kamal merges
# them. Kamal passes it to hooks as KAMAL_SERVICE. Empty when it can't be
# told: the file unreadable, or the value ERB.
kit_config_service() {
  local file=$1 dest=${2:-} service="" overlay
  case $file in /*) ;; *) file="$KIT_PROJECT_DIR/$file" ;; esac
  [ -r "$file" ] || return 0
  service=$(kit_yaml_get service "$file" || true)
  overlay="${file%.*}.$dest.yml" # Kamal: the extension replaced
  if [ -n "$dest" ] && [ -r "$overlay" ]; then
    overlay=$(kit_yaml_get service "$overlay" 2>/dev/null || true)
    [ -z "$overlay" ] || service=$overlay
  fi
  case $service in *"<%"*) return 0 ;; esac
  printf '%s\n' "$service"
}

# kit_group_setting NAME KEY: KEY as group NAME's group.env sets it (empty
# if it doesn't), without loading the group: the file sourced in a
# subshell, as kit_group_load reads it, so a value built from others
# (KIT_GROUP_ROLES="${APP}_a ${APP}_b") is what the deploy will use.
# As there too: KIT_GROUP and KIT_GROUP_DIR set, an unset variable an
# error (it fails, rather than read "${APP}_a" as "_a"), and a value the
# environment gives winning.
kit_group_setting() {
  local file
  file="$(kit_group_dir "$1")/group.env"
  [ -r "$file" ] || return 0
  (
    set -u
    KIT_GROUP=$1
    KIT_GROUP_DIR=$(kit_group_dir "$1")
    env=${!2-}
    kit_in_list "$2" "${KIT_ENV_NAMES:-}" || unset "$2"
    # shellcheck disable=SC1090
    . "$file" >/dev/null || exit 1
    kit_in_list "$2" "${KIT_ENV_NAMES:-}" && printf -v "$2" '%s' "$env"
    printf '%s\n' "${!2-}"
  ) || {
    kit_error "group $1: .kamal/groups/$1/group.env can't be read (above)"
    return 1
  }
}

# kit_group_roles_of NAME: a group's roles, read without loading it.
# Fails when group.env can't be read.
kit_group_roles_of() {
  local roles
  roles=$(kit_group_setting "$1" KIT_GROUP_ROLES) || return 1
  kit_words "$roles"
}

# kit_group_load NAME: reads group.env over the defaults and checks it.
kit_group_load() {
  local name=$1 dir count
  dir=$(kit_group_dir "$name")
  [ -f "$dir/group.env" ] || kit_die "no group '$name' (.kamal/groups/$name/group.env)"

  local internal env="" var
  # Set before, for group.env to use; set again after, whatever it did.
  KIT_GROUP=$name
  KIT_GROUP_DIR=$dir
  internal=$(kit_internal_set)
  # What the environment says wins over group.env too (KIT_ENV_NAMES: the
  # variables the kit was started with).
  for var in ${KIT_ENV_NAMES:-}; do
    kit_is_name "$var" && env="$env$(printf '%s=%q' "$var" "${!var-}")"$'\n'
  done
  set -a
  # shellcheck disable=SC1091
  . "$dir/group.env"
  set +a
  # Like the kit's files, group.env can't set the kit's own state.
  kit_scrub_internal "$internal"
  # A setting group.env gives beats kit.env's default for a destination
  # (KIT_GROUP_HEALTH_TIMEOUT_PRODUCTION there), unless group.env scopes
  # it itself.
  if [ -n "${KIT_DESTINATION:-}" ]; then
    local set_here scoped
    set_here=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\(KIT_[A-Z0-9_]*\)=.*/\2/p' "$dir/group.env")
    for var in $set_here; do
      scoped="${var}_$(kit_upper "$KIT_DESTINATION")"
      kit_in_list "$scoped" "$set_here" || kit_in_list "$scoped" "${KIT_ENV_NAMES:-}" || unset "$scoped"
    done
  fi
  eval "$env"
  KIT_GROUP=$name
  KIT_GROUP_DIR=$dir
  export KIT_GROUP KIT_GROUP_DIR
  # A group of another Kamal config brings its config along, so
  # `kit group deploy <name>` works without -c.
  if [ -n "${KIT_GROUP_KAMAL_CONFIG_FILE:-}" ]; then
    export KIT_KAMAL_CONFIG_FILE=$KIT_GROUP_KAMAL_CONFIG_FILE
  fi

  case "${KIT_GROUP_STRATEGY:-}" in
    standby) ;;
    rolling | pair) KIT_GROUP_STRATEGY=rolling ;;
    *) kit_die "group $name: KIT_GROUP_STRATEGY must be standby or rolling (is '${KIT_GROUP_STRATEGY:-}')" ;;
  esac

  count=$(kit_words "${KIT_GROUP_ROLES:-}" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ] || kit_die "group $name: KIT_GROUP_ROLES is empty"
  if [ "$KIT_GROUP_STRATEGY" = standby ]; then
    [ "$count" -eq 2 ] || kit_die "group $name: a standby group has exactly two roles (has $count)"
    _kit_group_has active || kit_die "group $name: a standby group needs an 'active' script or KIT_GROUP_ACTIVE_CMD"
  fi
}

# ---------------------------------------------------------------- scripts

# _kit_group_has SCRIPT: the group defines SCRIPT.
_kit_group_has() {
  local var
  var="KIT_GROUP_$(kit_upper "$1")_CMD"
  [ -x "$KIT_GROUP_DIR/$1" ] || [ -n "${!var:-}" ]
}

# _kit_group_call SCRIPT [VAR=VALUE...]: runs the group's SCRIPT with the
# given variables. Returns 0 when the group doesn't define it.
# Within a run, as the group's own: a script's `kamal app boot` (its hooks
# run despite -H) passes the role guard like the group's deploys do.
_kit_group_call() {
  local script=$1 var
  shift
  kit_in_run && set -- KIT_GROUP_DEPLOY="$KIT_GROUP" "$@"
  var="KIT_GROUP_$(kit_upper "$script")_CMD"
  if [ -x "$KIT_GROUP_DIR/$script" ]; then
    env "$@" "$KIT_GROUP_DIR/$script"
  elif [ -n "${!var:-}" ]; then
    env "$@" bash -c "${!var}"
  else
    return 0
  fi
}

# kit_group_is_active ROLE
kit_group_is_active() { _kit_group_call active KIT_ROLE="$1" >/dev/null 2>&1; }

# kit_group_is_healthy ROLE: the group's check, else "its container runs"
# (Kamal names the version running). Not `kit_role_exec ROLE true`: Kamal
# (Thor) takes a "true" after --raw for that option's value, and finds no
# command to run, so no role was ever healthy that way.
kit_group_is_healthy() {
  if _kit_group_has healthy; then
    _kit_group_call healthy KIT_ROLE="$1" >/dev/null 2>&1
  else
    [ -n "$(kit_role_version "$1")" ]
  fi
}

# kit_group_handover FROM TO: the group's handover, else restart FROM in
# place on the build it runs: its clean stop releases whatever makes it
# active (a lease, a lock) to TO, which must already be healthy.
kit_group_handover() {
  local from=$1 to=$2 from_version
  from_version=$(kit_role_version "$from")
  if _kit_group_has handover; then
    _kit_group_call handover KIT_FROM="$from" KIT_TO="$to" KIT_FROM_VERSION="$from_version"
  else
    # Not running (crashed during the deploy): nothing to restart; whether
    # TO has taken over is for the wait to tell.
    if [ -z "$from_version" ]; then
      kit_warn "$from isn't running: nothing to hand over from"
      return 0
    fi
    kit_kamal app stop -H -r "$from" &&
      _kit_group_start "$from" "$from_version"
  fi
}

# _kit_group_start ROLE VERSION: starts ROLE's stopped container of
# VERSION, and fails unless ROLE then runs it: Kamal (2.12) exits 0 for a
# role without the proxy when no container of VERSION is left (pruned),
# having started nothing.
_kit_group_start() {
  kit_kamal app start -H -r "$1" --version "$2" || return 1
  [ "$(kit_role_version "$1")" = "$2" ] && return 0
  kit_error "${KIT_GROUP:-group}: $1 isn't running $2 after \`kamal app start\` (no container of it left?)"
  return 1
}

# _kit_group_after_failed_handover FROM TO FROM-VERSION: after a handover
# that didn't end with TO active: FROM started again if it's down (it was
# stopped for the handover, or died), and what's left said as it is.
# Prints that state, for the notification.
_kit_group_after_failed_handover() {
  local from=$1 to=$2 from_version=$3 active rc=0 state
  if [ -n "$from_version" ] && [ -z "$(kit_role_version "$from")" ]; then
    kit_warn "$KIT_GROUP: $from is down: starting it again on $from_version"
    _kit_group_start "$from" "$from_version" >&2 ||
      kit_error "$KIT_GROUP: could not start $from again: it's down"
  fi
  active=$(kit_group_active_role) || rc=$?
  case $rc in
    0) state="$active is active" ;;
    1) state="no role is active" ;;
    *) state="both roles say they are active (split brain?)" ;;
  esac
  [ -n "$(kit_role_version "$from")" ] || state="$state; $from is down"
  kit_error "$KIT_GROUP: after the failed handover, $state"
  printf '%s\n' "$state"
}

# _kit_group_record FILE LINE: notes LINE in the run folder's FILE (what a
# deploy changed, for its rollback and its failure message).
_kit_group_record() {
  kit_in_run || return 0
  printf '%s\n' "$2" >>"$KIT_RUN_DIR/$1"
}

# _kit_group_version_arg KAMAL-DEPLOY-ARGS...: the --version among them.
_kit_group_version_arg() {
  while [ $# -gt 0 ]; do
    case $1 in
      --version) printf '%s\n' "${2:-}" && return 0 ;;
      --version=*) printf '%s\n' "${1#--version=}" && return 0 ;;
    esac
    shift
  done
}

# ----------------------------------------------------------------- waiting

_kit_group_timeout() { kit_conf "$1" "$2"; }

kit_group_wait_healthy() {
  local role=$1
  kit_info "waiting for $role to be healthy…"
  kit_wait_until "$(_kit_group_timeout KIT_GROUP_HEALTH_TIMEOUT 180)" "$(kit_conf KIT_GROUP_INTERVAL 2)" \
    kit_group_is_healthy "$role"
}

_kit_group_switched_to() { kit_group_is_active "$1" && ! kit_group_is_active "$2"; }

kit_group_wait_switched() {
  local to=$1 from=$2
  kit_info "waiting for $to to take over from ${from}…"
  kit_wait_until "$(_kit_group_timeout KIT_GROUP_SWITCH_TIMEOUT 90)" "$(kit_conf KIT_GROUP_INTERVAL 2)" \
    _kit_group_switched_to "$to" "$from"
}

# kit_group_active_role: the one active role; fails (1: none, 2: several).
kit_group_active_role() {
  local role active="" count=0
  for role in $(kit_words "$KIT_GROUP_ROLES"); do
    if kit_group_is_active "$role"; then
      active=$role
      count=$((count + 1))
    fi
  done
  [ "$count" -eq 1 ] && printf '%s\n' "$active" && return 0
  [ "$count" -eq 0 ] && return 1
  return 2
}

_kit_group_other() {
  local role
  for role in $(kit_words "$KIT_GROUP_ROLES"); do
    [ "$role" != "$1" ] && printf '%s\n' "$role" && return 0
  done
}

# -------------------------------------------------------------- deploying

# _kit_group_deploy_role ROLE KAMAL-DEPLOY-ARGS...: stop first (if set),
# deploy ROLE alone, wait until healthy. The deploy runs Kamal's hooks (the
# gates); KIT_GROUP_DEPLOY tells the role guard this deploy is the group's.
# A deploy that fails before the new container runs (a pull, a hook) would
# leave the role stopped: it's started again on the build it ran.
_kit_group_deploy_role() {
  local role=$1 stopped="" marker=""
  shift
  _kit_group_call before-role KIT_ROLE="$role" || {
    kit_error "$KIT_GROUP: before-role failed for $role"
    return 1
  }
  if kit_is_true "$(kit_conf KIT_GROUP_STOP_FIRST true)"; then
    stopped=$(kit_role_version "$role")
    if [ -n "$stopped" ]; then
      kit_info "stopping $role before replacing it (no overlap on its volumes and ports)"
      kit_kamal app stop -H -r "$role" || return 1
      # Interrupted from here (Ctrl-C, TERM), it's started again on its way
      # out, rather than left down.
      if kit_in_run; then
        marker="$KIT_RUN_DIR/stopped-$role"
        printf '%s\n' "$stopped" >"$marker"
        kit_at_exit "_kit_group_start_stopped '$role' '$stopped' '$marker'"
      fi
    fi
  fi
  kit_info "deploying $role"
  KIT_GROUP_DEPLOY=$KIT_GROUP kit_kamal deploy -r "$role" "$@" || {
    kit_error "$KIT_GROUP: deploying $role failed"
    [ -z "$marker" ] || rm -f "$marker"
    if [ -n "$stopped" ] && [ -z "$(kit_role_version "$role")" ]; then
      kit_warn "$KIT_GROUP: starting $role again on $stopped (it was stopped for the deploy)"
      _kit_group_start "$role" "$stopped" ||
        kit_error "$KIT_GROUP: could not start $role again: it's down"
    fi
    return 1
  }
  [ -z "$marker" ] || rm -f "$marker"
  kit_group_wait_healthy "$role" || {
    kit_error "$KIT_GROUP: $role did not become healthy"
    return 1
  }
  _kit_group_call after-role KIT_ROLE="$role" || {
    kit_error "$KIT_GROUP: after-role failed for $role"
    return 1
  }
}

# _kit_group_start_stopped ROLE VERSION MARKER: at exit, a role this run
# stopped for its deploy, and that runs nothing since, is started again.
_kit_group_start_stopped() {
  [ -f "$3" ] || return 0
  rm -f "$3"
  [ -z "$(kit_role_version "$1")" ] || return 0
  kit_warn "${KIT_GROUP:-group}: $1 was left stopped: starting it again on $2"
  _kit_group_start "$1" "$2" ||
    kit_error "could not start $1 again: it's down. kit kamal app start -H -r $1 --version $2"
}

# kit_group_deploy [--bootstrap] [KAMAL-DEPLOY-ARGS...]
kit_group_deploy() {
  local bootstrap=false
  if [ "${1:-}" = --bootstrap ]; then
    bootstrap=true
    shift
  fi
  _kit_group_gates "$@" || kit_die "$KIT_GROUP: a gate refused the deploy; nothing stopped, nothing deployed"
  _kit_group_call before || kit_die "$KIT_GROUP: 'before' failed; nothing deployed"
  case $KIT_GROUP_STRATEGY in
    standby) _kit_group_deploy_standby "$bootstrap" "$@" || return 1 ;;
    # (--bootstrap means nothing to a rolling group: each role is deployed.)
    rolling) _kit_group_deploy_rolling "$@" || return 1 ;;
  esac
  _kit_group_call after || {
    kit_warn "$KIT_GROUP: 'after' failed (the deploy itself succeeded)"
    kit_notify warning "$KIT_GROUP: deployed, but its 'after' script failed"
  }
  return 0
}

# _kit_group_gates KAMAL-DEPLOY-ARGS...: the pre-deploy gates (ci-green,
# freeze, the git ones...), before anything is stopped. They also run in
# each role's `kamal deploy`, but only after KIT_GROUP_STOP_FIRST stopped
# it: a red or unfinished CI would leave a standby down. Asked here with
# the variables Kamal gives hooks, they're cached for the run, and the
# deploys that follow find them passed.
_kit_group_gates() {
  local version roles service
  version=$(_kit_group_version_arg "$@")
  if [ -z "$version" ]; then
    version=$(kit_kamal_config_get version "$(kit_kamal_config)") || return 1
  fi
  roles=$(kit_words "$KIT_GROUP_ROLES" | tr '\n' ',')
  service=$(kit_config_service "$(kit_config_file "$(kit_conf KIT_KAMAL_CONFIG_FILE "")")" "${KIT_DESTINATION:-}")
  env KAMAL_COMMAND=deploy KAMAL_SUBCOMMAND= KAMAL_ROLES="${roles%,}" KAMAL_VERSION="$version" \
    KAMAL_SERVICE="$service" KAMAL_DESTINATION="${KIT_DESTINATION:-}" \
    KAMAL_PERFORMER="${KAMAL_PERFORMER:-${USER:-unknown}}" "$KIT_BIN" hook --gates pre-deploy
}

_kit_group_deploy_standby() {
  local bootstrap=$1 active rc=0 standby previous version active_version target state
  shift

  active=$(kit_group_active_role) || rc=$?
  if [ "$rc" -eq 2 ]; then
    kit_notify error "$KIT_GROUP: more than one role says it is active; not deploying"
    kit_die "$KIT_GROUP: more than one role says it is active (split brain?); fix that before deploying"
  fi

  if [ "$rc" -eq 1 ]; then
    if [ "$bootstrap" != true ]; then
      kit_notify error "$KIT_GROUP: no role is active; not deploying"
      kit_die "$KIT_GROUP: no role is active. First deploy? Run: kit group deploy $KIT_GROUP --bootstrap"
    fi
    # Only a group with nothing running: roles that run but that no one
    # says is active (an 'active' script failing, an SSH error) would both
    # be replaced, and the fallback lost.
    local role running="" v
    for role in $(kit_words "$KIT_GROUP_ROLES"); do
      # Strictly: an SSH error read as "nothing runs" would replace both.
      v=$(kit_role_version_strict "$role") ||
        kit_die "$KIT_GROUP: could not ask Kamal what $role runs, so not bootstrapping (both roles would be replaced)"
      [ -z "$v" ] || running="$running $role"
    done
    if [ -n "$running" ]; then
      kit_notify error "$KIT_GROUP: --bootstrap refused: no role is active, but$running run"
      kit_die "$KIT_GROUP: no role says it's active, but$running run: --bootstrap would replace both. Check \`kit group status $KIT_GROUP\` (the 'active' script?); to start over, stop them first (kit kamal app stop -r ROLE)"
    fi
    for role in $(kit_words "$KIT_GROUP_ROLES"); do
      _kit_group_deploy_role "$role" "$@" || return 1
      _kit_group_record "deployed-$KIT_GROUP" "$role"
    done
    if kit_wait_until "$(_kit_group_timeout KIT_GROUP_SWITCH_TIMEOUT 90)" "$(kit_conf KIT_GROUP_INTERVAL 2)" \
      kit_group_active_role >/dev/null; then
      kit_ok "$KIT_GROUP: bootstrapped; $(kit_group_active_role) is active"
      return 0
    fi
    rc=0
    kit_group_active_role >/dev/null || rc=$?
    if [ "$rc" -eq 2 ]; then
      kit_error "$KIT_GROUP: both roles deployed, and both say they are active (split brain?)"
    else
      kit_error "$KIT_GROUP: both roles deployed, but none became active"
    fi
    return 1
  fi

  standby=$(_kit_group_other "$active")
  previous=$(kit_role_version "$standby")
  active_version=$(kit_role_version "$active")
  target=$(_kit_group_version_arg "$@")

  # Deployed again (a retry after a failed handover, say): the active role
  # already on the build is done; one of them on it must not end with both.
  if [ -n "$target" ] && [ "$active_version" = "$target" ]; then
    kit_ok "$KIT_GROUP: $active is active on $target already; $standby keeps ${previous:-nothing}"
    return 0
  fi
  if [ -n "$target" ] && [ "$previous" = "$target" ]; then
    kit_info "$KIT_GROUP: $standby runs $target already; handing over to it"
    kit_group_wait_healthy "$standby" || {
      kit_notify error "$KIT_GROUP: $standby (on $target) isn't healthy; $active is still active, nothing switched"
      kit_error "$KIT_GROUP: $standby did not become healthy"
      return 1
    }
  else
    kit_info "$KIT_GROUP: $active is active; updating $standby"
    if ! _kit_group_deploy_role "$standby" "$@"; then
      _kit_group_restore "$standby" "$previous"
      kit_notify error "$KIT_GROUP: $standby failed to deploy; $active is still active on its build, nothing switched"
      return 1
    fi
  fi
  _kit_group_record "deployed-$KIT_GROUP" "$standby (standing by)"

  version=$(kit_role_version "$standby")
  kit_info "$KIT_GROUP: handing over from $active to $standby"
  if kit_group_handover "$active" "$standby" && kit_group_wait_switched "$standby" "$active"; then
    # For the rollback: this deploy switched the group.
    _kit_group_record "switched-$KIT_GROUP" "$standby"
    kit_ok "$KIT_GROUP: $standby is active on ${version:-the new build}; $active stands by on the previous build"
    return 0
  fi

  kit_error "$KIT_GROUP: $standby did not take over from $active"
  state=$(_kit_group_after_failed_handover "$active" "$standby" "$active_version")
  if [ "$(kit_conf KIT_GROUP_ON_SWITCH_FAILURE report)" = switch-back ]; then
    if [ -z "$(kit_role_version "$active")" ]; then
      kit_warn "$KIT_GROUP: not handing back: $active isn't running"
    else
      kit_warn "$KIT_GROUP: handing back to $active"
      if kit_group_handover "$standby" "$active" && kit_group_wait_switched "$active" "$standby"; then
        kit_warn "$KIT_GROUP: $active is active again"
        state="handed back: $active is active again"
      fi
    fi
  fi
  kit_notify error "$KIT_GROUP: handover from $active to $standby failed: $state"
  return 1
}

# A role that failed on its new build goes back to its previous one, when
# KIT_GROUP_RESTORE_ON_FAILURE is set (off by default: a broken standby
# isn't active anyway, and its logs say why; for a rolling group, turn it
# on so the failed role serves again).
_kit_group_restore() {
  local role=$1 previous=$2
  kit_is_true "$(kit_conf KIT_GROUP_RESTORE_ON_FAILURE false)" || return 0
  [ -n "$previous" ] || return 0
  kit_warn "$KIT_GROUP: restoring $role to $previous"
  kit_group_rollback_role "$role" "$previous" ||
    kit_warn "$KIT_GROUP: could not restore $role to $previous"
}

# kit_group_rollback_role ROLE VERSION: puts ROLE (of the loaded group)
# back on VERSION. Kamal's rollback starts the old container before
# stopping the new one, so, as for a deploy, the role is stopped first when
# KIT_GROUP_STOP_FIRST is set: otherwise both want its published port. A
# role already on VERSION is left alone (rolling back onto the running
# build would replace a container with a copy of itself).
# One that can't be rolled back (the old container pruned) is started again
# on the build it ran, rather than left stopped.
kit_group_rollback_role() {
  local role=$1 version=$2 current stopped=false
  current=$(kit_role_version "$role")
  if [ "$current" = "$version" ]; then
    kit_info "$role already runs $version: nothing to roll back"
    return 0
  fi
  if kit_is_true "$(kit_conf KIT_GROUP_STOP_FIRST true)" && [ -n "$current" ]; then
    kit_kamal app stop -H -r "$role" || return 1
    stopped=true
  fi
  if KIT_GROUP_DEPLOY=$KIT_GROUP kit_kamal rollback -H -r "$role" "$version"; then
    # Kamal (2.12) exits 0 when no container of VERSION is left (pruned),
    # having only said so: what runs tells.
    [ "$(kit_role_version "$role")" != "$version" ] || return 0
    kit_error "${KIT_GROUP:-group}: $role isn't on $version after the rollback (no container of it left?)"
  else
    kit_error "${KIT_GROUP:-group}: rolling $role back to $version failed"
  fi
  if [ "$stopped" = true ] && [ -z "$(kit_role_version "$role")" ]; then
    kit_warn "${KIT_GROUP:-group}: starting $role again on $current"
    _kit_group_start "$role" "$current" ||
      kit_error "${KIT_GROUP:-group}: could not start $role again: it's down"
  fi
  return 1
}

_kit_group_deploy_rolling() {
  local order="" role active=""
  if [ "$(kit_conf KIT_GROUP_ROLLING_ORDER listed)" = inactive-first ] && _kit_group_has active; then
    for role in $(kit_words "$KIT_GROUP_ROLES"); do
      if kit_group_is_active "$role"; then active="$active $role"; else order="$order $role"; fi
    done
    order="$order $active"
  else
    order=$KIT_GROUP_ROLES
  fi

  local done_roles="" previous
  for role in $(kit_words "$order"); do
    previous=$(kit_role_version "$role")
    if ! _kit_group_deploy_role "$role" "$@"; then
      _kit_group_restore "$role" "$previous"
      kit_notify error "$KIT_GROUP: rolling deploy stopped at $role;${done_roles:+ updated:$done_roles;} the rest keep their build"
      return 1
    fi
    done_roles="$done_roles $role"
    _kit_group_record "deployed-$KIT_GROUP" "$role"
  done
  kit_ok "$KIT_GROUP: updated$done_roles"
}

# kit_group_switch [TO [quiet]]: hands over to TO (default: the standby).
# Standby only. quiet: no success notice (a hand-back, which its caller
# reports).
kit_group_switch() {
  local to=${1:-} quiet=${2:-} active rc=0 active_version state
  [ "$KIT_GROUP_STRATEGY" = standby ] || kit_die "$KIT_GROUP: switch is for standby groups"
  active=$(kit_group_active_role) || rc=$?
  [ "$rc" -eq 0 ] || kit_die "$KIT_GROUP: can't switch: $([ "$rc" -eq 1 ] && echo "no role is active" || echo "more than one role is active")"
  [ -n "$to" ] || to=$(_kit_group_other "$active")
  kit_in_list "$to" "$KIT_GROUP_ROLES" || kit_die "$KIT_GROUP: $to isn't one of its roles"
  if [ "$to" = "$active" ]; then
    kit_ok "$KIT_GROUP: $to is already active"
    return 0
  fi
  kit_group_is_healthy "$to" || kit_die "$KIT_GROUP: $to isn't healthy; not switching to it"
  active_version=$(kit_role_version "$active")
  if kit_group_handover "$active" "$to" && kit_group_wait_switched "$to" "$active"; then
    kit_ok "$KIT_GROUP: $to is active ($(kit_role_version "$to")); $active stands by"
    # (Not when it's a hand-back, which its caller reports.)
    [ "$quiet" = true ] || kit_notify success "$KIT_GROUP: switched to $to; $active stands by"
    return 0
  fi
  kit_error "$KIT_GROUP: $to did not take over from $active"
  state=$(_kit_group_after_failed_handover "$active" "$to" "$active_version")
  kit_notify error "$KIT_GROUP: switch from $active to $to failed: $state"
  kit_die "$KIT_GROUP: $to did not take over from $active: $state"
}

# kit_group_status: each role's version, health and (if known) activity.
kit_group_status() {
  local role version health activity
  printf '%s (%s)\n' "$KIT_GROUP" "$KIT_GROUP_STRATEGY"
  for role in $(kit_words "$KIT_GROUP_ROLES"); do
    version=$(kit_role_version "$role")
    if kit_group_is_healthy "$role"; then health=healthy; else health=unhealthy; fi
    activity=""
    if _kit_group_has active; then
      if kit_group_is_active "$role"; then activity=active; else activity=standby; fi
    fi
    printf '  %-20s %-14s %-10s %s\n' "$role" "${version:-(not running)}" "$health" "$activity"
  done
}
