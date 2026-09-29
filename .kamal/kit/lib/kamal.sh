# shellcheck shell=bash
# Calling Kamal. Sourced after core.sh.
#
# Facts about Kamal this relies on (checked against Kamal 2.12's source):
# - `pre-connect` runs before the first command that reaches a server, for
#   any command. Nested `kamal` calls from the kit pass -H (skip hooks)
#   unless they are the deploy itself; `app` and `lock` commands run
#   pre-connect anyway (and `app boot` pre-app-boot): -H reaches the main
#   command's options, not theirs. They give hooks KAMAL_COMMAND=app (or
#   lock) and no subcommand.
# - A role without the proxy is replaced by starting the new container,
#   waiting until it runs (or its healthcheck passes), then stopping the old
#   one: the two overlap. Groups stop first when that matters.
# - `kamal app start` starts the container named for the *current* version
#   (the checkout's commit, or --version), so restarting a role that runs
#   another build needs --version.
# - `kamal app stop` stops the running container, whatever its version.

# kit_require_kamal: stops, before anything is attempted (or notified),
# when the configured Kamal command isn't here.
kit_require_kamal() {
  local kamal=()
  read -r -a kamal <<<"$(kit_conf KIT_KAMAL kamal)"
  command -v "${kamal[0]:-kamal}" >/dev/null 2>&1 && return 0
  kit_die "needs Kamal: '${kamal[*]}' isn't here (KIT_KAMAL). Install it (gem install kamal), or run it in the kit's image: KIT_RUNNER=docker (docs/runner.md)"
}

# kit_kamal WORDS... [OPTIONS...]: runs Kamal with the configured command,
# config file and destination. The global options go right after the
# command words (`app exec`, `deploy`), before the caller's own.
kit_kamal() {
  local kamal=() words=() globals=() file
  read -r -a kamal <<<"$(kit_conf KIT_KAMAL kamal)"
  [ ${#kamal[@]} -gt 0 ] || kamal=(kamal) # KIT_KAMAL= set empty

  # Command words: the first, and a second for Kamal's subcommand groups.
  if [ $# -gt 0 ]; then
    words+=("$1")
    case $1 in
      app | build | proxy | accessory | server | lock | prune | secrets | registry)
        shift
        [ $# -gt 0 ] && words+=("$1")
        ;;
    esac
    shift
  fi

  file=$(kit_conf KIT_KAMAL_CONFIG_FILE "")
  [ -n "$file" ] && globals+=(-c "$file")
  [ -n "${KIT_DESTINATION:-}" ] && globals+=(-d "$KIT_DESTINATION")

  "${kamal[@]}" ${words[@]+"${words[@]}"} ${globals[@]+"${globals[@]}"} "$@"
}

# kit_role_exec ROLE COMMAND: runs COMMAND (one string) in ROLE's running
# container, printing only its output. Fails if the container isn't running
# or COMMAND fails.
kit_role_exec() {
  local role=$1 cmd=$2
  if kit_is_true "$(kit_conf KIT_KAMAL_EXEC_RAW true)"; then
    kit_kamal app exec -H -q -r "$role" --reuse --raw "$cmd"
  else
    kit_kamal app exec -H -q -r "$role" --reuse "$cmd" | sed '/^App Host: /d'
  fi
}

# kit_role_version ROLE: the version ROLE's running container runs, empty
# when none runs, or when Kamal couldn't be asked (kit_role_version_strict
# tells those apart). With several hosts, the first; a mismatch is warned
# about.
kit_role_version() { kit_role_version_strict "$1" || true; }

# kit_role_version_strict ROLE: kit_role_version, failing when Kamal
# couldn't be asked (an SSH error): "nothing runs" is then unknown.
kit_role_version_strict() {
  local role=$1 out versions first
  out=$(kit_kamal app version -H -q -r "$role" 2>/dev/null) || return 1
  # In host order, each once: the first is the first host's.
  versions=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d; /^App Host: /d' | awk '!seen[$0]++')
  first=$(printf '%s\n' "$versions" | sed -n 1p)
  if [ "$(printf '%s\n' "$versions" | sed '/^$/d' | wc -l | tr -d ' ')" -gt 1 ]; then
    kit_warn "$role runs different versions on its hosts: $(printf '%s' "$versions" | tr '\n' ' ')"
  fi
  printf '%s\n' "$first"
}

# kit_kamal_config: `kamal config`'s output (empty when it fails). Within a
# run, asked once per Kamal config and destination: each call boots Kamal.
kit_kamal_config() {
  local cache="" out
  if kit_in_run; then
    cache="$KIT_RUN_DIR/config-$(printf '%s' "$(kit_conf KIT_KAMAL_CONFIG_FILE "")@${KIT_DESTINATION:-}" | tr -c 'A-Za-z0-9._@-' '_')"
    if [ -f "$cache" ]; then
      cat "$cache"
      return 0
    fi
  fi
  out=$(kit_kamal config 2>/dev/null) || out=""
  [ -z "$cache" ] || [ -z "$out" ] || printf '%s\n' "$out" >"$cache"
  printf '%s\n' "$out"
}

# kit_kamal_config_get PATH OUTPUT: a value from `kamal config`'s OUTPUT
# (Kamal's view of the config: destination merged, ERB evaluated), read
# by kit_yaml_get (lib/yaml.sh): a value, a list's values one per line, a
# map's KEY=VALUE lines; nothing when it isn't there. Stops the kit when
# Kamal printed it in a shape the kit can't read, rather than guess.
# Callers: value=$(kit_kamal_config_get PATH "$out") || exit 1
kit_kamal_config_get() {
  local value status=0
  value=$(printf '%s\n' "$2" | kit_yaml_get "$1") || status=$?
  case $status in
    0) [ -z "$value" ] || printf '%s\n' "$value" ;;
    1) ;;
    *) kit_die "could not read $1 from \`kamal config\`" ;;
  esac
}

# kit_all_roles: every role, from KIT_ROLES or `kamal config`.
kit_all_roles() {
  local roles out
  roles=$(kit_conf KIT_ROLES "")
  if [ -z "$roles" ]; then
    out=$(kit_kamal_config)
    roles=$(kit_kamal_config_get roles "$out") || exit 1
  fi
  [ -n "$roles" ] || kit_die "could not tell the roles: set KIT_ROLES in .kamal/kit.env"
  kit_words "$roles"
}
