# shellcheck shell=bash
# The hook dispatcher: `kit hook <name>`, which every .kamal/hooks/<name>
# shim runs. Sourced after core.sh and notify.sh.
#
# A hook runs, in order:
#   1. the steps listed in KIT_HOOK_<NAME> (e.g. KIT_HOOK_PRE_DEPLOY), each
#      a project step (.kamal/steps/<step>), a kit step (steps/<step>), or a
#      path relative to the project;
#   2. every executable in .kamal/hooks.d/<name>/, in name order.
# The first failing step fails the hook (and so Kamal's command), after a
# notification saying which step failed and why.
#
# Kamal hands hooks its secrets in the environment: steps must never print
# or send the environment.

# kit_hook_run [--gates] NAME: runs hook NAME. Unknown hook names work too
# (a hook Kamal adds later just needs a shim and a KIT_HOOK_ list).
# --gates: only its listed steps that are cached per run (KIT_CACHED_STEPS),
# not the project's hooks.d scripts, so that a command can pass the gates
# before it changes anything Kamal won't (a group stopping a role first):
# `kit hook --gates pre-deploy`. Kamal's own run of the hook then finds
# them passed.
kit_hook_run() {
  local gates=false hook var step path skip reason rc started cached unskippable
  local steps=()
  if [ "${1:-}" = --gates ]; then
    gates=true
    shift
  fi
  hook=$1

  # A kamal command run from inside a step (a migration through `kamal app
  # exec`, say) would run pre-connect again: the outer command's hooks
  # already ran, so nested ones do nothing. KIT_IN_HOOK is <hook>:<pid>,
  # and counts only while that hook's process is one of ours: a value left
  # in a shell, or set by hand, turns no gate off.
  # Only for the same project, though: a hook's script deploying another
  # one (cd ../other && kamal deploy) would run it with no gates, and under
  # the lock of this one (KAMAL_LOCK=true is inherited): refused.
  # The project is where Kamal runs (its .kamal/hooks are there): two apps
  # of one repository are two projects.
  local root
  root=$(pwd -P)
  if [ -n "${KIT_IN_HOOK:-}" ]; then
    if _kit_hook_outer_running "$KIT_IN_HOOK"; then
      if [ -n "${KIT_IN_HOOK_ROOT:-}" ] && [ "$KIT_IN_HOOK_ROOT" != "$root" ]; then
        kit_die "$hook: Kamal runs for $root from a hook of $KIT_IN_HOOK_ROOT: it would run without its own gates and lock. Deploy it outside the hook"
      fi
      return 0
    fi
    kit_warn "$hook: KIT_IN_HOOK=$KIT_IN_HOOK isn't a hook of this command: ignored, the steps run"
  fi
  export KIT_IN_HOOK="$hook:$$" KIT_IN_HOOK_ROOT="$root"

  # Not a step: no list or skip can leave it out.
  if [ "$hook" = pre-build ] && [ "$gates" != true ]; then
    _kit_build_version_check || return 1
  fi

  var="KIT_HOOK_$(kit_upper "$hook")"
  for step in $(kit_words "$(kit_conf "$var" "")"); do steps+=("$step"); done
  # The project's scripts by glob, not by word: its path may hold spaces.
  if [ "$gates" != true ] && [ -d "$KIT_CONFIG_DIR/hooks.d/$hook" ]; then
    for step in "$KIT_CONFIG_DIR/hooks.d/$hook"/*; do
      [ -f "$step" ] && [ -x "$step" ] && steps+=("$step")
    done
  fi
  skip=$(kit_conf KIT_SKIP "")
  reason=$(kit_conf KIT_SKIP_REASON "")
  cached=$(kit_conf KIT_CACHED_STEPS "")
  unskippable=$(kit_committed_conf KIT_UNSKIPPABLE) || return 1
  unskippable=$(kit_words "$unskippable" | tr '\n' ' ')
  # A step that can't be skipped can't be left out of the lists either.
  if [ "$hook" = pre-deploy ] && [ "$gates" != true ]; then
    _kit_unskippable_listed "$unskippable" || return 1
  fi

  for step in ${steps[@]+"${steps[@]}"}; do
    if [ "$gates" = true ] && ! kit_in_list "$(basename "$step")" "$cached"; then
      continue
    fi
    if kit_in_list "$(basename "$step")" "$skip"; then
      if kit_in_list "$(basename "$step")" "$unskippable"; then
        kit_error "$hook: $(basename "$step") can't be skipped${KIT_DESTINATION:+ on $KIT_DESTINATION} (KIT_UNSKIPPABLE, in the committed kit.env)"
        kit_notify error "$hook: refused to skip $(basename "$step") (KIT_UNSKIPPABLE), by ${KAMAL_PERFORMER:-${USER:-unknown}}"
        return 1
      fi
      kit_skip_reason_check || return 1
      kit_warn "$hook: skipping $step (KIT_SKIP${reason:+: $reason})"
      # Once per kit run: each group's deploy runs the hooks again.
      if _kit_skip_first "$(basename "$step")"; then
        kit_notify warning "$hook: step $(basename "$step") skipped by KIT_SKIP${reason:+ (\"$reason\")}, by ${KAMAL_PERFORMER:-${USER:-unknown}}"
      fi
      continue
    fi

    # Within kit deploy, the smoke tests run once, at its end (the project's
    # own smoke step too: failing here, the deploy would stop half-way).
    # A group deployed on its own runs them after each role, here.
    if [ "$hook" = post-deploy ] && [ "$(basename "$step")" = smoke ] && kit_smoke_at_end; then
      continue
    fi

    path=$(_kit_hook_resolve "$step") || {
      kit_error "$hook: no step named '$step' (looked in .kamal/steps/, the kit's steps/, and as a path)"
      kit_notify error "$hook: no step named '$step'"
      return 1
    }
    if kit_in_list "$(basename "$step")" "$unskippable"; then
      _kit_step_committed "$hook" "$path" || return 1
    fi

    if _kit_hook_cached "$hook" "$step"; then
      kit_info "$hook: $step already passed in this run"
      continue
    fi

    started=$SECONDS
    rc=0
    KIT_HOOK=$hook KIT_STEP=$step kit_timeout "$(_kit_step_timeout "$step")" "$path" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 124 ]; then
        kit_error "$hook: $step timed out after $((SECONDS - started))s"
      else
        kit_error "$hook: $step failed (exit $rc)"
      fi
      kit_notify error "${KAMAL_COMMAND:-deploy} stopped: $hook step '$step' failed (version ${KAMAL_SERVICE_VERSION:-${KAMAL_VERSION:-?}}, by ${KAMAL_PERFORMER:-unknown})"
      return "$rc"
    fi
    _kit_hook_cache "$hook" "$step"
  done
  return 0
}

# _kit_build_version_check: a build is of HEAD (Kamal builds the checkout,
# or a clone of HEAD), whatever version it's tagged with. A version naming
# another commit (`--version`, `VERSION=`, `kit deploy -- --version`) would
# put HEAD's build under that commit's tag, and the gates would check that
# commit instead of what's built. Versions that aren't commit ids (v1.2) are
# HEAD's by definition: the gates check HEAD for them.
_kit_build_version_check() {
  local version=${KAMAL_VERSION:-} sha head
  sha=${version%%_uncommitted_*}
  kit_is_commit_id "$sha" || return 0
  head=$(git -C "$KIT_PROJECT_DIR" rev-parse HEAD 2>/dev/null) || head=""
  if [ -n "$head" ]; then
    case $head in "$sha"*) return 0 ;; esac
  fi
  kit_error "pre-build: version $version isn't the checkout's commit (${head:-no commit}): Kamal builds the checkout and would tag it $version. Check out $sha, or deploy its image (--skip-push)"
  kit_notify error "build of ${KAMAL_SERVICE:+$KAMAL_SERVICE }$version refused: the checkout is ${head:0:12}, by ${KAMAL_PERFORMER:-unknown}"
  return 1
}

# _kit_hook_outer_running HOOK:PID: PID is a running ancestor of this
# process, and is `kit hook` (the outer hook). From the whole process
# table: busybox's ps (the kit's image) has no -p.
_kit_hook_outer_running() {
  local pid=${1##*:}
  kit_is_int "$pid" && [ "$pid" -gt 1 ] || return 1
  ps -A -o pid= -o ppid= -o args= 2>/dev/null | awk -v self=$$ -v outer="$pid" '
    { parent[$1] = $2; args[$1] = " " $0 " " }
    END {
      if (!(outer in args) || args[outer] !~ / hook /) exit 1
      p = self
      for (i = 0; i < 64 && (p in parent) && p > 1; i++) {
        p = parent[p]
        if (p == outer) exit 0
      }
      exit 1
    }'
}

# _kit_step_timeout STEP: KIT_STEP_TIMEOUT_<STEP>, else KIT_STEP_TIMEOUT;
# for ci-green, at least KIT_CI_WAIT and a minute, so that waiting for CI
# ends with CI's verdict, not with the step killed.
_kit_step_timeout() {
  local name timeout wait
  name=$(basename "$1")
  timeout=$(kit_conf "KIT_STEP_TIMEOUT_$(kit_upper "$name")" "$(kit_conf KIT_STEP_TIMEOUT 600)")
  if [ "$name" = ci-green ] && kit_is_int "$timeout" && [ "$timeout" -gt 0 ]; then
    wait=$(kit_conf KIT_CI_WAIT 0)
    kit_is_int "$wait" && [ "$timeout" -lt $((wait + 60)) ] && timeout=$((wait + 60))
  fi
  printf '%s\n' "$timeout"
}

# _kit_unskippable_listed UNSKIPPABLE: each step listed by some hook
# (KIT_HOOK_*): a list set in kit.local.env or the environment could
# otherwise leave out what KIT_SKIP can't skip.
_kit_unskippable_listed() {
  local step h all="" missing=""
  for h in ${KIT_KAMAL_HOOKS:-pre-connect pre-build pre-deploy post-deploy}; do
    # pre-app-boot guards only `kamal app boot`: the role guard there
    # doesn't count for a deploy.
    [ "$h" = pre-app-boot ] && continue
    all="$all $(kit_conf "KIT_HOOK_$(kit_upper "$h")" "")"
  done
  for step in $1; do
    case " $(kit_words "$all" | while read -r s; do basename "$s"; done | tr '\n' ' ') " in
      *" $step "*) ;;
      *) missing="$missing $step" ;;
    esac
  done
  [ -n "$missing" ] || return 0
  kit_error "pre-deploy:$missing can't be skipped${KIT_DESTINATION:+ on $KIT_DESTINATION} (KIT_UNSKIPPABLE), and no hook lists it (KIT_HOOK_*)"
  kit_notify error "deploy refused:$missing left out of the hooks, though KIT_UNSKIPPABLE, by ${KAMAL_PERFORMER:-${USER:-unknown}}"
  return 1
}

# _kit_step_committed HOOK PATH: an unskippable step runs from where its
# name says: the project's .kamal/steps/ (or hooks.d/) or the kit's steps/, committed as
# it is when it's in the project (a vendored kit too). A path to anything
# else of the same name (KIT_HOOK_PRE_DEPLOY=/tmp/require-branch, set
# locally) would replace it with anything.
_kit_step_committed() {
  local hook=$1 path=$2 name
  name=$(basename "$path")
  local hook_dir=${path#"$KIT_CONFIG_DIR/hooks.d/"}
  hook_dir=${hook_dir%/"$name"}
  case $path in
    "$KIT_CONFIG_DIR/steps/$name") ;;
    "$KIT_CONFIG_DIR/hooks.d/"*/"$name")
      # hooks.d/<hook>/<name> itself, not a way out of it (..).
      case $hook_dir in */* | . | .. | "")
        kit_error "$hook: $name can't be skipped (KIT_UNSKIPPABLE), so it runs from .kamal/steps/ or the kit's steps/, not $path"
        return 1
        ;;
      esac
      ;;
    "$KIT_HOME/steps/$name")
      case $KIT_HOME in "$KIT_PROJECT_DIR"/*) ;; *) return 0 ;; esac
      ;;
    *)
      kit_error "$hook: $name can't be skipped (KIT_UNSKIPPABLE), so it runs from .kamal/steps/ or the kit's steps/, not $path"
      kit_notify error "$hook: refused $path in place of the unskippable $name, by ${KAMAL_PERFORMER:-${USER:-unknown}}"
      return 1
      ;;
  esac
  if git -C "$KIT_PROJECT_DIR" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 &&
    git -C "$KIT_PROJECT_DIR" diff --quiet HEAD -- "$path" 2>/dev/null; then
    return 0
  fi
  kit_error "$hook: ${path#"$KIT_PROJECT_DIR"/} can't be skipped (KIT_UNSKIPPABLE), and isn't committed as it is: commit it, or remove it to use the kit's"
  kit_notify error "$hook: refused ${path#"$KIT_PROJECT_DIR"/}, an uncommitted version of an unskippable step, by ${KAMAL_PERFORMER:-${USER:-unknown}}"
  return 1
}

# kit_skip_reason_check: when KIT_SKIP skips anything, KIT_SKIP_REASON must
# say why if KIT_SKIP_REASON_REQUIRED (e.g. _PRODUCTION) is on, in the
# configuration or in the committed kit.env (which the environment and
# kit.local.env can't turn off).
kit_skip_reason_check() {
  [ -n "$(kit_conf KIT_SKIP "")" ] || return 0
  [ -z "$(kit_conf KIT_SKIP_REASON "")" ] || return 0
  local committed v required=false
  kit_is_true "$(kit_conf KIT_SKIP_REASON_REQUIRED false)" && required=true
  committed=$(kit_committed_conf KIT_SKIP_REASON_REQUIRED) || return 1
  for v in $committed; do kit_is_true "$v" && required=true; done
  [ "$required" = true ] || return 0
  kit_error "skipping steps${KIT_DESTINATION:+ on $KIT_DESTINATION} needs a reason: KIT_SKIP_REASON=\"why\" (KIT_SKIP_REASON_REQUIRED)"
  return 1
}

# kit_skip_unskippable_check: KIT_SKIP names no step KIT_UNSKIPPABLE holds.
kit_skip_unskippable_check() {
  local step skip unskippable bad=""
  skip=$(kit_conf KIT_SKIP "")
  [ -n "$skip" ] || return 0
  unskippable=$(kit_committed_conf KIT_UNSKIPPABLE) || return 1
  for step in $(kit_words "$skip"); do
    kit_in_list "$step" "$unskippable" && bad="$bad $step"
  done
  [ -n "$bad" ] || return 0
  kit_error "can't skip${bad}${KIT_DESTINATION:+ on $KIT_DESTINATION} (KIT_UNSKIPPABLE, in the committed kit.env)"
  return 1
}

# _kit_skip_first STEP: true the first time STEP is skipped in this kit run
# (always, outside one).
_kit_skip_first() {
  kit_in_run || return 0
  [ ! -f "$KIT_RUN_DIR/skipped-$1" ] || return 1
  : >"$KIT_RUN_DIR/skipped-$1"
}

# _kit_hook_resolve STEP: the executable to run for STEP.
_kit_hook_resolve() {
  local step=$1
  # The sandbox checks only its own URLs, with the kit's smoke step: a
  # project's is for its real servers.
  if [ "$step" = smoke ] && kit_in_sandbox; then
    printf '%s\n' "$KIT_HOME/steps/smoke"
    return 0
  fi
  case $step in
    /*) [ -x "$step" ] && printf '%s\n' "$step" && return 0 ;;
    */*) [ -x "$KIT_PROJECT_DIR/$step" ] && printf '%s\n' "$KIT_PROJECT_DIR/$step" && return 0 ;;
    *)
      if [ -x "$KIT_CONFIG_DIR/steps/$step" ]; then
        printf '%s\n' "$KIT_CONFIG_DIR/steps/$step"
        return 0
      fi
      if [ -x "$KIT_HOME/steps/$step" ]; then
        printf '%s\n' "$KIT_HOME/steps/$step"
        return 0
      fi
      ;;
  esac
  return 1
}

# Within one `kit deploy` (KIT_RUN_DIR set), a gate that passed for this
# version isn't run again by the next `kamal deploy -r …` of the same run:
# CI is asked once, and the confirmation is asked once.
_kit_hook_cache_file() {
  printf '%s/passed-%s-%s' "$KIT_RUN_DIR" "$(basename "$2")" "${KAMAL_VERSION:-none}"
}

_kit_hook_cached() {
  kit_in_run || return 1
  kit_in_list "$(basename "$2")" "$(kit_conf KIT_CACHED_STEPS "")" || return 1
  [ -f "$(_kit_hook_cache_file "$1" "$2")" ]
}

_kit_hook_cache() {
  kit_in_run || return 0
  kit_in_list "$(basename "$2")" "$(kit_conf KIT_CACHED_STEPS "")" || return 0
  : >"$(_kit_hook_cache_file "$1" "$2")"
}
