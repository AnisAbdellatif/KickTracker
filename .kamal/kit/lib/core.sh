# shellcheck shell=bash
# Core helpers shared by every deploy-kit command and step: logging, lists,
# configuration loading, timeouts and waiting. Sourced, never run.
#
# Portable to bash 3.2 (macOS's /bin/bash): no associative arrays, no
# ${var,,}, no mapfile. Deploys are often run from a Mac.

KIT_HOME=${KIT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export KIT_HOME

# shellcheck source=yaml.sh
. "$KIT_HOME/lib/yaml.sh"

# ---------------------------------------------------------------- logging

_kit_color() {
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then printf '\033[%sm' "$1"; fi
}

kit_log() { printf '%skit%s %s\n' "$(_kit_color 2)" "$(_kit_color 0)" "$*" >&2; }
kit_info() { kit_log "$*"; }
kit_ok() { printf '%skit ✓%s %s\n' "$(_kit_color 32)" "$(_kit_color 0)" "$*" >&2; }
kit_warn() { printf '%skit !%s %s\n' "$(_kit_color 33)" "$(_kit_color 0)" "$*" >&2; }
kit_error() { printf '%skit ✗%s %s\n' "$(_kit_color 31)" "$(_kit_color 0)" "$*" >&2; }
kit_die() {
  kit_error "$*"
  exit 1
}

# kit_gate_die MESSAGE: a gate refusing, and how to go past it once, on
# purpose (the step's name comes from the hook running it: KIT_STEP).
kit_gate_die() {
  local hint=""
  [ -z "${KIT_STEP:-}" ] ||
    hint=" To go past it once, on purpose: KIT_SKIP=$(basename "$KIT_STEP") KIT_SKIP_REASON=\"why\" before the command (warned and notified)"
  kit_die "$1.$hint"
}

# ------------------------------------------------------------------ values

# These run in loops, in every hook: plain bash, no processes started.

# kit_is_true VALUE: 1, true, yes, on (any case).
kit_is_true() {
  case ${1:-} in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

# kit_upper TEXT: upper case, with - and . turned into _ (for variable names).
kit_upper() { printf '%s' "$1" | tr '[:lower:].-' '[:upper:]__'; }

# kit_words LIST: one item per line; items separated by spaces, commas or
# newlines. Empty items are dropped; nothing is globbed.
kit_words() {
  local word IFS=$' \t\n,' glob=true
  case $- in *f*) glob=false ;; esac
  set -f
  # shellcheck disable=SC2086 # split on IFS, globbing off
  for word in ${1:-}; do
    [ -z "$word" ] || printf '%s\n' "$word"
  done
  [ "$glob" = false ] || set +f
}

# kit_in_list ITEM LIST: whether ITEM is one of LIST's words.
kit_in_list() {
  local item=${1:-} sep=$',\t\n'
  [ -n "$item" ] || return 1
  case " ${2//[$sep]/ } " in
    *" $item "*) return 0 ;;
    *) return 1 ;;
  esac
}

# kit_is_name VALUE: a valid variable name (safe inside a regex).
kit_is_name() { [[ ${1:-} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# kit_is_int VALUE: a non-negative integer.
kit_is_int() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ------------------------------------------------------------ configuration
#
# Configuration is shell variables named KIT_*, read from, in order (later
# wins):
#
#   $KIT_HOME/lib/defaults.sh           the kit's defaults
#   .kamal/kit.env                      the project's settings (committed)
#   .kamal/kit.<destination>.env        per destination (committed)
#   .kamal/kit.local.env                personal overrides (git-ignored)
#   the environment                     KIT_*=… kit deploy …, or any variable
#                                       the files set (KT_HOST=… …)
#
# A value can also be given per destination inside any of these with a
# suffix: KIT_DEPLOY_BRANCH_STAGING=dev beats KIT_DEPLOY_BRANCH for
# `-d staging` (see kit_conf). Everything read is exported, so steps and
# group scripts see the same configuration.

# kit_project_dir: the project's root (the git top level, else the current
# directory), unless KIT_PROJECT_DIR says otherwise.
kit_project_dir() {
  if [ -n "${KIT_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$KIT_PROJECT_DIR"
  else
    git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}

# kit_load_config [DESTINATION]: loads the files above. DESTINATION defaults
# to KIT_DESTINATION, then KAMAL_DESTINATION (set by Kamal for hooks).
# The kit's own state, passed from a kit process to the ones it starts.
# Never taken from a file (kit.env, kit.local.env, group.env): set there,
# KIT_IN_HOOK or KIT_SANDBOX would turn every gate off, unseen.
# Per-process caches (kit_in_run, kit_ps_works): never taken from the
# environment, where they'd turn the run folder's check off.
unset _KIT_RUN_CHECKED _KIT_PS_WORKS

KIT_INTERNAL_VARS="KIT_IN_HOOK KIT_RUN_DIR KIT_GROUP_DEPLOY KIT_SANDBOX KIT_IN_RUNNER KIT_HOOK KIT_STEP KIT_GROUP KIT_GROUP_DIR
  KIT_HOST_NAME KIT_HOST_PID KIT_HOST_PIDS KIT_HOST_PIDS_AT KIT_ENV_NAMES KIT_IN_HOOK_ROOT"

# kit_scrub_internal SET-BEFORE: unsets the internal variables that weren't
# set before a file was sourced (SET-BEFORE: their names, space-separated).
kit_scrub_internal() {
  local var
  for var in $KIT_INTERNAL_VARS; do
    case " $1 " in *" $var "*) ;; *) unset "$var" ;; esac
  done
}

# kit_internal_set: the internal variables set now.
kit_internal_set() {
  local var out=""
  for var in $KIT_INTERNAL_VARS; do
    [ -z "${!var+set}" ] || out="$out $var"
  done
  printf '%s\n' "$out"
}

# A second argument, FILE (relative to .kamal/), is read after the others,
# under the same rules: the sandbox's own settings (sandbox/sandbox.env).
kit_load_config() {
  local dest=${1:-${KIT_DESTINATION:-${KAMAL_DESTINATION:-}}} extra=${2:-}
  local saved="" var file internal names=""

  # What the environment says wins over the files, for every variable: a
  # script that sets KT_HOST (the sandbox, a rehearsal) must never lose to
  # the real server's address in kit.local.env. Remember the environment
  # (and any KIT_* set in this shell), then put it back after the files.
  for var in $( (compgen -e; compgen -v KIT_) 2>/dev/null | sort -u); do
    # (Read-only ones too: SHELLOPTS and BASHOPTS, when exported, can't be
    # put back.)
    case $var in KIT_HOME | KIT_LOADED | PWD | OLDPWD | SHLVL | _ | BASH_* | FUNCNAME | SHELLOPTS | BASHOPTS) continue ;; esac
    kit_is_name "$var" || continue
    saved="$saved$(printf '%s=%q' "$var" "${!var-}")"$'\n'
    case $var in KIT_*) names="$names $var" ;; esac
  done

  KIT_PROJECT_DIR=$(kit_project_dir)
  KIT_CONFIG_DIR=${KIT_CONFIG_DIR:-$KIT_PROJECT_DIR/.kamal}
  internal=$(kit_internal_set)

  set -a
  # shellcheck source=defaults.sh
  . "$KIT_HOME/lib/defaults.sh"
  for file in \
    "$KIT_CONFIG_DIR/kit.env" \
    ${dest:+"$KIT_CONFIG_DIR/kit.$dest.env"} \
    "$KIT_CONFIG_DIR/kit.local.env" \
    ${extra:+"$KIT_CONFIG_DIR/$extra"}; do
    if [ -f "$file" ]; then
      # shellcheck disable=SC1090
      . "$file"
    fi
  done
  # The project's own Kamal config, before -c (which comes through the
  # environment) replaces it: groups that don't name a config belong to it.
  if [ -z "${KIT_PROJECT_KAMAL_CONFIG_FILE+set}" ]; then
    KIT_PROJECT_KAMAL_CONFIG_FILE=${KIT_KAMAL_CONFIG_FILE:-}
  fi
  kit_scrub_internal "$internal"
  eval "$saved"
  set +a
  # The KIT_* variables the kit was started with, for group.env (sourced
  # later) to lose to as well. Passed on: a kit the kit starts sees the
  # files' values in its environment, and must not take those for yours.
  [ -n "${KIT_ENV_NAMES+set}" ] || KIT_ENV_NAMES=${names# }
  export KIT_ENV_NAMES

  KIT_DESTINATION=$dest
  KIT_LOADED=1
  export KIT_PROJECT_DIR KIT_CONFIG_DIR KIT_DESTINATION KIT_LOADED
}

# kit_conf NAME [DEFAULT]: NAME's value for the current destination:
# NAME_<DESTINATION> if set, else NAME if set, else DEFAULT. Set to empty
# counts as set (KIT_SMOKE_URLS_STAGING= turns smoke tests off for staging).
kit_conf() {
  local name=$1 default=${2:-} scoped
  if [ -n "${KIT_DESTINATION:-}" ]; then
    # The destination's suffix, worked out once per destination.
    if [ "${_KIT_DEST_FOR:-}" != "$KIT_DESTINATION" ]; then
      _KIT_DEST_SUFFIX=$(kit_upper "$KIT_DESTINATION")
      _KIT_DEST_FOR=$KIT_DESTINATION
    fi
    scoped="${name}_$_KIT_DEST_SUFFIX"
    if [ -n "${!scoped+set}" ]; then
      printf '%s\n' "${!scoped}"
      return
    fi
  fi
  if [ -n "${!name+set}" ]; then
    printf '%s\n' "${!name}"
  else
    printf '%s\n' "$default"
  fi
}

# kit_env_get KEY FILE: KEY's value in a dotenv file, parsed, never sourced
# (a value with spaces or $ would otherwise run). Read as the shell would
# read the simple cases: a quoted value up to its closing quote, an
# unquoted one up to a comment (` # …`) or the end; what follows is
# dropped. The last assignment wins.
kit_env_get() {
  local key=$1 file=$2
  [ -r "$file" ] || return 1
  kit_env_parse "$key" <"$file"
}

# kit_env_parse KEY: kit_env_get, from stdin.
kit_env_parse() {
  local key=$1 value
  kit_is_name "$key" || kit_die "not a variable name: $key"
  value=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${key}[[:space:]]*=//p" | tail -n 1)
  case $value in
    \"*) value=${value#\"} && value=${value%%\"*} ;;
    \'*) value=${value#\'} && value=${value%%\'*} ;;
    *)
      value=${value%%[[:space:]]#*}
      value=${value%"${value##*[![:space:]]}"}
      ;;
  esac
  printf '%s\n' "$value"
}

# -------------------------------------------------------------- processes

# kit_descendants PID: PID's children, their children…, one per line.
kit_descendants() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { pid[NR] = $1; parent[NR] = $2 }
    END {
      tree[root] = 1
      do {
        grew = 0
        for (i = 1; i <= NR; i++)
          if (!(pid[i] in tree) && (parent[i] in tree)) { tree[pid[i]] = 1; print pid[i]; grew = 1 }
      } while (grew)
    }'
}

# kit_kill_tree SIGNAL PID: PID and everything it started. Killing PID
# alone would leave its children running, holding the caller's pipes.
kit_kill_tree() {
  local sig=$1 pid=$2 pids
  pids=$(kit_descendants "$pid")
  # shellcheck disable=SC2086 # one pid per word
  kill "-$sig" "$pid" $pids 2>/dev/null || true
}

# kit_timeout SECONDS COMMAND...: runs COMMAND, killing it and what it
# started after SECONDS (0 or empty: no limit). Exit status 124 on
# timeout, like timeout(1), which macOS doesn't ship. COMMAND runs in the
# background, so its stdin is /dev/null: anything interactive must read
# /dev/tty. And it ignores Ctrl-C, like any background job of a script:
# an interrupt (or TERM) of the kit stops it here, then the kit.
kit_timeout() {
  local secs=$1 rc
  shift
  if ! kit_is_int "$secs" || [ "$secs" -eq 0 ]; then
    "$@"
    return
  fi
  "$@" &
  _KIT_TIMEOUT_PID=$!
  (
    sleep "$secs"
    kit_kill_tree TERM "$_KIT_TIMEOUT_PID"
    sleep 5
    kit_kill_tree KILL "$_KIT_TIMEOUT_PID"
  ) </dev/null >/dev/null 2>&1 3>&- &
  _KIT_TIMEOUT_WATCHER=$!
  trap '_kit_timeout_stop; kit_signal_traps; exit 130' INT
  trap '_kit_timeout_stop; kit_signal_traps; exit 143' TERM
  rc=0
  wait "$_KIT_TIMEOUT_PID" || rc=$?
  kit_signal_traps
  # KILL: the watcher only sleeps, and TERM may be ignored here for good (a
  # hook run from the kit's exit, where signals are ignored, inherits that).
  kit_kill_tree KILL "$_KIT_TIMEOUT_WATCHER"
  wait "$_KIT_TIMEOUT_WATCHER" 2>/dev/null || true
  case $rc in 137 | 143) rc=124 ;; esac
  return "$rc"
}

_kit_timeout_stop() {
  kit_kill_tree KILL "$_KIT_TIMEOUT_WATCHER"
  kit_kill_tree TERM "$_KIT_TIMEOUT_PID"
}

# kit_committed_conf NAME: NAME as the committed configuration sets it
# (.kamal/kit.env and kit.<destination>.env, read not sourced;
# NAME_<DESTINATION> first), ignoring the environment, kit.local.env and
# uncommitted edits: for policy that a deployer can't turn off for
# themselves (KIT_UNSKIPPABLE, KIT_SKIP_REASON_REQUIRED). One line per
# commit it's read from: HEAD, and the remote's deploy branches as last
# fetched (a local commit lifting the policy lifts it only at HEAD).
# Callers take them all (a list's union; true if any says so). Fails when
# the project is a git checkout whose HEAD can't be read (not a repository
# git trusts, say): no policy is never assumed then.
kit_committed_conf() {
  local name=$1 rel remote branches="" b ref dir head=true
  if git -C "$KIT_PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    # No commit here yet (a new repository, an orphan branch): nothing at
    # HEAD, but the remote's deploy branches still count.
    git -C "$KIT_PROJECT_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || head=false
  else
    # Not a repository git reads: fine when there's none (no .git here or
    # above), not when there's one it refuses (not trusted, say).
    dir=$(cd "$KIT_PROJECT_DIR" 2>/dev/null && pwd -P) || return 0
    while [ ! -e "$dir/.git" ] && [ "$dir" != / ] && [ -n "$dir" ]; do dir=$(dirname "$dir"); done
    [ -e "$dir/.git" ] || return 0
    kit_error "can't read the committed configuration (git fails in $dir), so not its $name either"
    return 1
  fi
  rel=${KIT_CONFIG_DIR#"$KIT_PROJECT_DIR"/}
  if [ "$head" = true ]; then
    _kit_committed_at HEAD "$rel" "$name"
    branches=$(_kit_committed_at HEAD "$rel" KIT_DEPLOY_BRANCH)
  fi
  remote=$(kit_conf KIT_GIT_REMOTE origin)
  branches="$branches $(kit_conf KIT_DEPLOY_BRANCH main)"
  for b in $(kit_words "$branches" | awk '!seen[$0]++'); do
    ref="refs/remotes/$remote/$b"
    git -C "$KIT_PROJECT_DIR" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
    _kit_committed_at "$ref" "$rel" "$name"
  done
}

# _kit_committed_at COMMIT DIR NAME: NAME in COMMIT's DIR/kit.env and
# kit.<destination>.env.
_kit_committed_at() {
  local commit=$1 rel=$2 name=$3 file content value="" scoped="" v sname=""
  for file in "$rel/kit.env" ${KIT_DESTINATION:+"$rel/kit.$KIT_DESTINATION.env"}; do
    content=$(git -C "$KIT_PROJECT_DIR" show "$commit:./$file" 2>/dev/null) || continue
    v=$(printf '%s\n' "$content" | kit_env_parse "$name")
    if printf '%s\n' "$content" | grep -Eq "^[[:space:]]*(export[[:space:]]+)?${name}="; then value=$v; fi
    if [ -n "${KIT_DESTINATION:-}" ]; then
      sname="${name}_$(kit_upper "$KIT_DESTINATION")"
      v=$(printf '%s\n' "$content" | kit_env_parse "$sname")
      if printf '%s\n' "$content" | grep -Eq "^[[:space:]]*(export[[:space:]]+)?${sname}="; then scoped="set:$v"; fi
    fi
  done
  if [ -n "$scoped" ]; then printf '%s\n' "${scoped#set:}"; else printf '%s\n' "$value"; fi
}

# ---------------------------------------------------------------- the run
#
# A `kit deploy` (or a `kit group deploy` of its own) keeps a folder for
# the run, KIT_RUN_DIR, which its Kamal commands' hooks share: gates that
# passed, skips already notified, `kamal config`. Its .kit-run file marks
# it as the kit's: a KIT_RUN_DIR without it (left in a shell, or set by
# hand) is not trusted with gates "already passed".

# kit_at_exit COMMAND: runs COMMAND (a string) when the kit exits, however
# it does: done, failed, interrupted (Ctrl-C) or terminated. The last one
# registered runs first.
_KIT_AT_EXIT=""
kit_at_exit() {
  _KIT_AT_EXIT="$1${_KIT_AT_EXIT:+
$_KIT_AT_EXIT}"
  trap _kit_run_at_exit EXIT
  kit_signal_traps
}

# kit_signal_traps: INT, TERM and HUP exit (running the exit commands).
kit_signal_traps() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

_kit_run_at_exit() {
  local cmd
  set +e
  # A second Ctrl-C mustn't cut the lock's release short.
  trap '' INT TERM HUP
  while IFS= read -r cmd; do
    [ -z "$cmd" ] || eval "$cmd"
  done <<<"$_KIT_AT_EXIT"
  _KIT_AT_EXIT=""
}

# kit_run_dir_new: creates and exports KIT_RUN_DIR (removed on exit). Its
# mark holds this process's id: the run is this process's and its
# descendants'.
kit_run_dir_new() {
  KIT_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kit-run.XXXXXX")
  printf '%s\n' "$$" >"$KIT_RUN_DIR/.kit-run"
  kit_ps_works || kit_warn "no ps here (procps): the run's folder is trusted by its mark alone, and a deploy lock left by a dead run isn't told from a live one"
  export KIT_RUN_DIR
  kit_at_exit "rm -rf '$KIT_RUN_DIR'"
}

# kit_in_run: within a run the kit started: the folder has the kit's mark,
# and the process that made it is this one or one of its ancestors. A run
# folder made by hand (the mark copied, gates "passed") counts for nothing.
# Checked once per process and folder. Without ps (slim images), the
# ancestry can't be read: the mark alone counts, as before 0.7.5 (said
# when the run starts).
kit_in_run() {
  local owner
  [ -n "${KIT_RUN_DIR:-}" ] && [ -f "$KIT_RUN_DIR/.kit-run" ] || return 1
  [ "${_KIT_RUN_CHECKED:-}" != "$KIT_RUN_DIR" ] || return 0
  owner=$(sed -n 1p "$KIT_RUN_DIR/.kit-run")
  kit_is_int "$owner" || return 1
  if [ "$owner" = "$$" ] || ! kit_ps_works || kit_is_ancestor "$owner"; then
    _KIT_RUN_CHECKED=$KIT_RUN_DIR
    return 0
  fi
  return 1
}

# kit_smoke_at_end: within a `kit deploy`, which runs the smoke tests (or
# decided not to) once, at its end.
kit_smoke_at_end() { kit_in_run && [ -f "$KIT_RUN_DIR/smoke-at-end" ]; }

# kit_ps_works: ps lists this machine's processes (once per process).
kit_ps_works() {
  if [ -z "${_KIT_PS_WORKS:-}" ]; then
    if ps -A -o pid= >/dev/null 2>&1; then _KIT_PS_WORKS=yes; else _KIT_PS_WORKS=no; fi
  fi
  [ "$_KIT_PS_WORKS" = yes ]
}

# kit_is_ancestor PID: PID is an ancestor of this process (from the whole
# process table: busybox's ps, the kit's image, has no -p).
kit_is_ancestor() {
  local pid=$1
  kit_is_int "$pid" && [ "$pid" -gt 1 ] || return 1
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v self=$$ -v target="$pid" '
    { parent[$1] = $2 }
    END {
      p = self
      for (i = 0; i < 64 && (p in parent) && p > 1; i++) {
        p = parent[p]
        if (p == target) exit 0
      }
      exit 1
    }'
}

# kit_sandbox_skip: in a gate, stops it (exit 0) when running for `kit
# sandbox`: local, nothing to check against GitHub, the branch or a
# freeze. Only for the sandbox destination: KIT_SANDBOX anywhere else is
# refused, never a quiet way past the gates.
kit_sandbox_skip() {
  kit_in_sandbox || return 0
  kit_info "sandbox: $(basename "$0") skipped"
  exit 0
}

# kit_in_sandbox: running for `kit sandbox` (KIT_SANDBOX, destination
# sandbox). KIT_SANDBOX with another destination stops the kit.
kit_in_sandbox() {
  [ -n "${KIT_SANDBOX:-}" ] || return 1
  [ "${KIT_DESTINATION:-}" = sandbox ] ||
    kit_die "KIT_SANDBOX is set, but the destination is '${KIT_DESTINATION:-none}': it's for \`kit sandbox\` only (unset it)"
}

# kit_wait_until TIMEOUT INTERVAL COMMAND...: runs COMMAND every INTERVAL
# seconds until it succeeds (0) or TIMEOUT seconds have passed (1).
kit_wait_until() {
  local timeout=$1 interval=$2 deadline
  shift 2
  deadline=$((SECONDS + timeout))
  while :; do
    if "$@"; then return 0; fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep "$interval"
  done
}

# kit_require COMMAND [HINT]: fails with a clear message when a tool is missing.
kit_require() {
  command -v "$1" >/dev/null 2>&1 || kit_die "needs '$1'${2:+ ($2)}"
}

# kit_version_being_deployed: Kamal's version in a hook (a commit id by
# default, <sha>_uncommitted_<hash> for a dirty tree, or whatever VERSION /
# --version said), else HEAD's commit.
kit_version_being_deployed() {
  if [ -n "${KAMAL_VERSION:-}" ]; then
    printf '%s\n' "$KAMAL_VERSION"
  else
    git -C "$(kit_project_dir)" rev-parse HEAD
  fi
}

# kit_is_sha VALUE: a full or abbreviated (7+) hex commit id.
kit_is_sha() {
  case "${1:-}" in
    *[!0-9a-f]* | '') return 1 ;;
    *) [ "${#1}" -ge 7 ] ;;
  esac
}

# kit_is_commit_id VALUE: VALUE is a commit id, known here or not: hex,
# 7+ characters, with a letter in it, or 40 characters, or naming a commit
# this checkout has. Digits alone that name none (a date, 20260929; a
# build number) are a label, as Kamal takes them: the build is HEAD's. An
# unknown id with a letter isn't: taken for a label, a short id of a
# commit not fetched here would let HEAD be built under its name.
kit_is_commit_id() {
  local commit
  kit_is_sha "${1:-}" || return 1
  case $1 in *[a-f]*) return 0 ;; esac
  [ "${#1}" -eq 40 ] && return 0
  # As an id: a tag or branch named 20260929 doesn't make the label one.
  commit=$(git -C "$(kit_project_dir)" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
  case $commit in "$1"*) return 0 ;; esac
  return 1
}

# kit_is_rollback: this hook runs for `kamal rollback`.
kit_is_rollback() { [ "${KAMAL_COMMAND:-}" = rollback ]; }
