# shellcheck shell=bash
# sops helpers. Sourced after core.sh.
#
# With Kamal, secrets are read on the machine that deploys, in
# .kamal/secrets[.<destination>], which may run commands:
#
#   DATABASE_URL=$(.kamal/kit/bin/kit sops get config/secrets/production.sops.env DATABASE_URL)
#
# kit_sops_decrypt_dir is for files decrypted on a server (cron scripts,
# a compose stack next to Kamal), written so a failed decryption leaves the
# running configuration as it was.

# The --input-type/--output-type sops needs for FILE (dotenv files are
# named *.env; others go by their extension, which sops recognises).
_kit_sops_types() {
  case $1 in
    *.env) printf '%s\n' "--input-type dotenv --output-type dotenv" ;;
    *) printf '\n' ;;
  esac
}

# kit_sops_env FILE: FILE decrypted, to stdout.
kit_sops_env() {
  local file=$1 types
  kit_require sops "https://github.com/getsops/sops"
  [ -f "$file" ] || kit_die "no such file: $file"
  types=$(_kit_sops_types "$file")
  # shellcheck disable=SC2086
  sops --decrypt $types "$file"
}

# kit_sops_get FILE KEY: one value from an encrypted dotenv file. Fails if
# KEY isn't there (a secret missing must not become an empty string).
kit_sops_get() {
  local file=$1 key=$2 plain value
  kit_is_name "$key" || kit_die "not a variable name: $key"
  plain=$(kit_sops_env "$file") || kit_die "could not decrypt $file (is your age key in place?)"
  if ! printf '%s\n' "$plain" | grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*="; then
    kit_die "$key isn't set in $file"
  fi
  value=$(printf '%s\n' "$plain" | sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${key}[[:space:]]*=//p" | tail -n 1)
  case $value in
    \"*\") value=${value#\"} && value=${value%\"} ;;
    \'*\') value=${value#\'} && value=${value%\'} ;;
  esac
  printf '%s\n' "$value"
}

# kit_sops_decrypt_dir DIR: every DIR/*.sops.* becomes the same name without
# ".sops" (app.sops.env -> app.env), mode 0600. All are decrypted to
# temporary files first; only if every one worked are they moved into place.
# However it ends (a failure, Ctrl-C, TERM), no plaintext is left behind.
_KIT_SOPS_TMPS=""
kit_sops_decrypt_dir() {
  local dir=$1 file out tmp pair failed=0 outs=()
  kit_require sops "https://github.com/getsops/sops"
  kit_at_exit _kit_sops_cleanup
  for file in "$dir"/*.sops.*; do
    [ -f "$file" ] || continue
    # The file's name only: a folder named *.sops.* stays as it is.
    out="$dir/$(basename "$file" | sed 's/\.sops\././')"
    # A new file of our own (mode 0600) in the same folder, never an
    # existing one or a symlink put in its place; renamed over $out after.
    tmp=$(umask 077 && mktemp "$dir/.$(basename "$out").XXXXXX") || kit_die "could not write in $dir: nothing replaced"
    _KIT_SOPS_TMPS="$_KIT_SOPS_TMPS$tmp"$'\n'
    if kit_sops_env "$file" >"$tmp"; then
      outs+=("$out|$tmp")
    else
      kit_error "could not decrypt $file"
      rm -f "$tmp"
      failed=1
    fi
  done
  if [ "$failed" -ne 0 ]; then
    for pair in ${outs[@]+"${outs[@]}"}; do rm -f "${pair#*|}"; done
    kit_die "nothing replaced: the configuration in place is unchanged"
  fi
  for pair in ${outs[@]+"${outs[@]}"}; do
    mv -f "${pair#*|}" "${pair%%|*}"
    kit_ok "decrypted $(basename "${pair%%|*}")"
  done
}

# The temporary files decrypt-dir made that are still there (at exit).
_kit_sops_cleanup() {
  local tmp
  while IFS= read -r tmp; do
    [ -z "$tmp" ] || rm -f "$tmp"
  done <<<"$_KIT_SOPS_TMPS"
  _KIT_SOPS_TMPS=""
}
