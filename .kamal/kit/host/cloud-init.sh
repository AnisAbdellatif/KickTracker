#!/usr/bin/env bash
# Prints cloud-init user data that runs host/setup.sh with the given
# options on a new VPS's first boot. Paste it in the provider's "user
# data" / "cloud-init" field when creating the server:
#
#   kit host cloud-init --ssh-key-file ~/.ssh/id_ed25519.pub --timezone UTC > user-data.yaml
#
# Takes host/setup.sh's options. Key files are read here, on your machine,
# and their keys passed on (the server can't read your files); every key
# is checked first, so a private key never ends up in the user data. The
# script is embedded (base64), so what runs is exactly this checkout's
# version. On the server: progress in /var/log/kit-host-setup.log, the
# outcome in /var/lib/kit-host-setup/ok or failed (and `cloud-init status`).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=local-args.sh
. "$here/local-args.sh"
for arg in "$@"; do
  case $arg in
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
  esac
done
HOST_ARGS=()
kit_host_args "$@"
args=(${HOST_ARGS[@]+"${HOST_ARGS[@]}"})

# YAML single-quoted string: ' doubled.
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

script_b64=$(base64 <"$here/setup.sh" | tr -d '\n')

printf '#cloud-config\n'
printf '# deploy-kit host setup (%s); the script runs once, on first boot.\n' "$(cat "$here/../VERSION" 2>/dev/null || echo dev)"
printf 'write_files:\n'
printf '  - path: /root/kit-host-setup.sh\n'
printf '    permissions: "0700"\n'
printf '    encoding: b64\n'
printf '    content: %s\n' "$script_b64"
printf 'runcmd:\n'
printf '  - - bash\n'
printf '    - -c\n'
printf '    - %s\n' "$(yaml_quote 'bash /root/kit-host-setup.sh "$@" >>/var/log/kit-host-setup.log 2>&1')"
printf '    - kit-host-setup\n'
for arg in ${args[@]+"${args[@]}"}; do
  printf '    - %s\n' "$(yaml_quote "$arg")"
done
