# shellcheck shell=bash
# host/setup.sh's options as they leave this machine, for host/cloud-init.sh
# and `kit host remote`. Key files are read here (the server can't read
# yours), and every key is checked here, before anything is printed or
# sent: a private key (a key file given without its .pub) must never end
# up in user data or on a server. Sourced; bash 3.2 (a Mac's) is enough.

# kit_host_args ARGS...: HOST_ARGS, ARGS with each --ssh-key-file and
# --admin-key-file turned into the --ssh-key / --admin-key options of its
# keys (blank lines and comments left out). Exits on a file it can't read,
# or anything given as a key that isn't a public one.
kit_host_args() {
  local opt line file
  HOST_ARGS=()
  while [ $# -gt 0 ]; do
    case $1 in
      --ssh-key-file | --admin-key-file)
        opt=--ssh-key
        [ "$1" = --admin-key-file ] && opt=--admin-key
        file=${2:-}
        [ -r "$file" ] || _kit_host_die "can't read $file ($1)"
        while IFS= read -r line || [ -n "$line" ]; do
          line=${line%$'\r'}
          line=${line#"${line%%[![:space:]]*}"}
          case $line in '' | '#'*) continue ;; esac
          kit_host_check_key "$line" "${file##*/}"
          HOST_ARGS+=("$opt" "$line")
        done <"$file"
        shift 2
        ;;
      --ssh-key | --admin-key)
        if [ $# -ge 2 ]; then
          kit_host_check_key "$2" "$1"
          HOST_ARGS+=("$1" "$2")
          shift
        else
          HOST_ARGS+=("$1") # setup.sh says it needs a value
        fi
        shift
        ;;
      *) HOST_ARGS+=("$1") && shift ;;
    esac
  done
}

# kit_host_check_key KEY WHERE: KEY is an SSH public key (as host/setup.sh
# takes them); a private key is refused without being shown.
kit_host_check_key() {
  local re='^(ssh-|ecdsa-|sk-)[A-Za-z0-9@._-]+[[:space:]]+AAAA[A-Za-z0-9+/]*=*([[:space:]].*)?$'
  case $1 in
    *-----BEGIN* | *"PRIVATE KEY"*)
      _kit_host_die "$2 holds a private key, not a public one (the .pub file?): nothing sent"
      ;;
  esac
  [[ $1 =~ $re ]] || _kit_host_die "$2: doesn't look like an SSH public key: ${1:0:30}…"
}

_kit_host_die() {
  printf 'kit ✗ %s\n' "$*" >&2
  exit 1
}
