#!/usr/bin/env bash
# deploy-kit host setup: turns a fresh Debian/Ubuntu VPS into a host Kamal
# can deploy to as an unprivileged user. Idempotent: safe to run again,
# e.g. to add a key or a port. Runs as root:
#
#   kit host remote root@<host> --ssh-key "$(cat ~/.ssh/id_ed25519.pub)"
#   kit host cloud-init --ssh-key-file ~/.ssh/id_ed25519.pub > user-data.yaml
#   curl … | sudo bash -s -- [options]      (or copy it over and run it)
#
# What it does (each part can be turned off):
#   user        a deploy user (default "deploy"), in the docker group, with
#               your SSH keys; no password, no sudo
#   docker      Docker Engine from Docker's apt repository, its signing key
#               checked against the published fingerprint
#   ssh         keys only, no passwords, root by key only (or not at all
#               with --admin-user), fewer auth tries, no forwarding for
#               the deploy user; checked with sshd -T once reloaded
#   firewall    ufw: deny incoming except SSH (from anywhere, or only
#               --ssh-allow-from; rate-limited with --ssh-limit) and --ports
#   upgrades    unattended security upgrades
#   swap        a swap file when there is none (--swap 2G; 0 to skip)
#   fail2ban    optional (--fail2ban)
#   age         optional: an age key for the deploy user, for secrets
#               decrypted on the server (--age)
#
# Note: ports Docker publishes bypass ufw (Docker writes its own iptables
# rules). Kamal's proxy publishes 80/443 on purpose; anything else should
# be published on 127.0.0.1 or kept on Docker's network. docs/host.md.
#
# How it ended: /var/lib/kit-host-setup/ok, or failed (with the error),
# for a run nobody watched (cloud-init, on first boot).
set -euo pipefail

DEPLOY_USER=deploy
SSH_KEYS=()
SSH_PORT=22
SSH_LIMIT=false
SSH_FROM=()
PORTS="80,443"
TIMEZONE=""
SWAP=2G
ADMIN_USER=""
ADMIN_KEYS=()
DO_DOCKER=true
DO_SSH=true
DO_FIREWALL=true
DO_UPGRADES=true
DO_FAIL2BAN=false
DO_AGE=false
DIRS=()

# Docker's apt repository signing key (https://docs.docker.com/engine/install/).
DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

usage() {
  cat <<'EOF'
host/setup.sh [options]   (as root)
  --user NAME             deploy user (default: deploy)
  --ssh-key "KEY"         public key for the deploy user (repeatable)
  --ssh-key-file FILE     public keys file for the deploy user (repeatable)
  --admin-user NAME       also create a sudo user for humans; root login is then disabled
  --admin-key "KEY"       public key for the admin user (repeatable; default: the deploy keys)
  --admin-key-file FILE   public keys file for the admin user (repeatable)
  --ssh-port PORT         SSH port kept open in the firewall (default: 22; doesn't move sshd)
  --ssh-allow-from CIDR   SSH only from these addresses (repeatable, or comma separated)
  --ssh-limit             rate-limit SSH (ufw limit: an address is blocked after 6
                          connections in 30 s, which a Kamal deploy can reach)
  --ports LIST            other TCP ports to open, comma separated (default: 80,443)
  --timezone ZONE         e.g. UTC or Europe/Paris
  --swap SIZE             swap file size when there is no swap (default: 2G; 0: none)
  --dir PATH              a directory owned by the deploy user (repeatable), e.g. /srv/app
  --fail2ban              install fail2ban for sshd
  --age                   give the deploy user an age key (prints the public key)
  --no-docker --no-ssh-hardening --no-firewall --no-auto-upgrades
EOF
}

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!!  %s\033[0m\n' "$*" >&2; }
FAILURE=""
die() {
  FAILURE=$*
  printf '\033[31mxx  %s\033[0m\n' "$*" >&2
  exit 1
}

# check_key KEY: an SSH public key, on one line. A private key (a key file
# named without its .pub) is refused without being shown.
check_key() {
  case $1 in
    *-----BEGIN* | *"PRIVATE KEY"*) die "a private key was given where a public key goes (the .pub file?): refused" ;;
  esac
  [[ $1 =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@._-]+[[:space:]]+AAAA[A-Za-z0-9+/]*=*([[:space:]].*)?$ ]] ||
    die "doesn't look like an SSH public key: ${1:0:30}…"
}

# read_keys FILE: its lines, blank ones and comments left out.
read_keys() { grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" || true; }

# need "$@": the option in $1 has a value in $2.
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case $1 in
    --user | --ssh-key | --ssh-key-file | --admin-user | --admin-key | --admin-key-file | --ssh-port | \
      --ssh-allow-from | --ports | --timezone | --swap | --dir) need "$@" ;;
  esac
  case $1 in
    --ssh-key-file | --admin-key-file) [ -r "$2" ] || die "can't read $2" ;;
  esac
  case $1 in
    --user) DEPLOY_USER=$2 && shift ;;
    --ssh-key) SSH_KEYS+=("$2") && shift ;;
    --ssh-key-file)
      while IFS= read -r line; do [ -n "$line" ] && SSH_KEYS+=("$line"); done <<<"$(read_keys "$2")"
      shift
      ;;
    --admin-user) ADMIN_USER=$2 && shift ;;
    --admin-key) ADMIN_KEYS+=("$2") && shift ;;
    --admin-key-file)
      while IFS= read -r line; do [ -n "$line" ] && ADMIN_KEYS+=("$line"); done <<<"$(read_keys "$2")"
      shift
      ;;
    --ssh-port) SSH_PORT=$2 && shift ;;
    --ssh-allow-from)
      IFS=',' read -r -a from <<<"$2"
      for cidr in ${from[@]+"${from[@]}"}; do [ -z "$cidr" ] || SSH_FROM+=("$cidr"); done
      shift
      ;;
    --ssh-limit) SSH_LIMIT=true ;;
    --ports) PORTS=$2 && shift ;;
    --timezone) TIMEZONE=$2 && shift ;;
    --swap) SWAP=$2 && shift ;;
    --dir) DIRS+=("$2") && shift ;;
    --fail2ban) DO_FAIL2BAN=true ;;
    --age) DO_AGE=true ;;
    --no-docker) DO_DOCKER=false ;;
    --no-ssh-hardening) DO_SSH=false ;;
    --no-firewall) DO_FIREWALL=false ;;
    --no-auto-upgrades) DO_UPGRADES=false ;;
    -h | --help) usage && exit 0 ;;
    *) die "unknown option $1 (--help)" ;;
  esac
  shift
done

# ------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || die "run as root"

# How it ended, for a run nobody watched: ok, or failed with the error.
MARKS=/var/lib/kit-host-setup
mkdir -p "$MARKS"
rm -f "$MARKS/ok" "$MARKS/failed"
finish() {
  local status=$? now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$now" >"$MARKS/ok"
  else
    printf '%s exit %s: %s\n' "$now" "$status" "${FAILURE:-see the output (cloud-init: /var/log/kit-host-setup.log)}" >"$MARKS/failed"
  fi
}
trap finish EXIT

[ -r /etc/os-release ] || die "no /etc/os-release: Debian or Ubuntu only"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian | ubuntu) ;;
  *) die "Debian or Ubuntu only (this is ${ID:-unknown})" ;;
esac
[[ $DEPLOY_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: $DEPLOY_USER"
[ -z "$ADMIN_USER" ] || [[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: $ADMIN_USER"
[[ $SSH_PORT =~ ^[0-9]+$ ]] || die "invalid SSH port: $SSH_PORT"
[[ $PORTS =~ ^[0-9,]*$ ]] || die "--ports takes numbers separated by commas"
for key in ${SSH_KEYS[@]+"${SSH_KEYS[@]}"} ${ADMIN_KEYS[@]+"${ADMIN_KEYS[@]}"}; do
  check_key "$key"
done
for cidr in ${SSH_FROM[@]+"${SSH_FROM[@]}"}; do
  [[ $cidr =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || die "--ssh-allow-from takes addresses or ranges (CIDR): $cidr"
done

# admin_has_key: someone who can become root can still log in by key:
# root, or a sudo user (the one running this through sudo, a cloud
# image's default user). The deploy user doesn't count: it has no sudo.
admin_has_key() {
  local user home
  [ -s /root/.ssh/authorized_keys ] && return 0
  for user in ${SUDO_USER:-} $(getent group sudo admin wheel 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
    [ -n "$user" ] && [ "$user" != root ] || continue
    home=$(getent passwd "$user" | cut -d: -f6)
    [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ] && return 0
  done
  return 1
}

# Never lock ourselves out: hardening SSH needs a key that will still work.
if [ "$DO_SSH" = true ]; then
  if [ -n "$ADMIN_USER" ]; then
    [ ${#ADMIN_KEYS[@]} -gt 0 ] || [ ${#SSH_KEYS[@]} -gt 0 ] || [ -s "/home/$ADMIN_USER/.ssh/authorized_keys" ] ||
      die "--admin-user disables root login: give it a key (--admin-key or --ssh-key)"
  elif ! admin_has_key; then
    die "SSH hardening turns passwords off, and root has no SSH key (nor has any sudo user): --ssh-key only lets the deploy user in, without sudo. Pass --admin-user NAME (a sudo user, with --admin-key or the --ssh-key keys), or put a key in root's ~/.ssh/authorized_keys first"
  fi
fi

export DEBIAN_FRONTEND=noninteractive
# apt_get ARGS...: waits for the dpkg lock (on first boot, unattended-upgrades
# often holds it) instead of failing at once.
apt_get() { apt-get -o DPkg::Lock::Timeout=600 "$@"; }
apt_install() { apt_get install -y -q --no-install-recommends "$@" >/dev/null; }

log "packages"
apt_get update -q >/dev/null
apt_install ca-certificates curl gnupg

if [ -n "$TIMEZONE" ]; then
  log "timezone $TIMEZONE"
  timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
fi

# ------------------------------------------------------------------ users

# add_keys USER KEYS...: appends keys not already there. Never through a
# symlink: root would write, chown and chmod whatever it points to.
add_keys() {
  local user=$1 home dir file key
  shift
  home=$(getent passwd "$user" | cut -d: -f6)
  dir="$home/.ssh"
  file="$dir/authorized_keys"
  if [ -L "$home" ] || [ -L "$dir" ] || [ -L "$file" ]; then
    die "$file, or a folder above it, is a symlink: not writing through it (make them a plain folder and file)"
  fi
  install -d -m 700 -o "$user" -g "$user" "$dir"
  touch "$file"
  for key in "$@"; do
    grep -qxF "$key" "$file" || printf '%s\n' "$key" >>"$file"
  done
  chown "$user:$user" "$file"
  chmod 600 "$file"
}

log "user $DEPLOY_USER"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
passwd -l "$DEPLOY_USER" >/dev/null 2>&1 || true # no password login, ever
[ ${#SSH_KEYS[@]} -eq 0 ] || add_keys "$DEPLOY_USER" "${SSH_KEYS[@]}"
for dir in ${DIRS[@]+"${DIRS[@]}"}; do
  install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$dir"
done

if [ -n "$ADMIN_USER" ]; then
  log "admin user $ADMIN_USER"
  apt_install sudo
  id "$ADMIN_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER"
  usermod -aG sudo "$ADMIN_USER"
  if [ ${#ADMIN_KEYS[@]} -gt 0 ]; then
    add_keys "$ADMIN_USER" "${ADMIN_KEYS[@]}"
  elif [ ${#SSH_KEYS[@]} -gt 0 ]; then
    add_keys "$ADMIN_USER" "${SSH_KEYS[@]}"
  fi
  # Keys only, so sudo can't ask for a password the user doesn't have.
  # Checked before it's in place (a broken file there breaks all of sudo):
  # written beside it under a name with a dot, which sudo skips, then renamed.
  sudoers=$(mktemp /etc/sudoers.d/.kit.XXXXXX)
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >"$sudoers"
  chmod 440 "$sudoers"
  if ! visudo -cf "$sudoers" >/dev/null; then
    rm -f "$sudoers"
    die "the sudoers file for $ADMIN_USER didn't validate: not installed"
  fi
  mv -f "$sudoers" "/etc/sudoers.d/90-kit-$ADMIN_USER"
fi

# ----------------------------------------------------------------- docker

if [ "$DO_DOCKER" = true ]; then
  log "docker"
  if ! command -v docker >/dev/null 2>&1; then
    install -d -m 755 /etc/apt/keyrings
    key=$(mktemp)
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o "$key"
    # apt trusts every key in the file: it must hold exactly one, Docker's.
    keys=$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^pub:/ { n++ } END { print n + 0 }')
    fingerprint=$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
    if [ "$keys" != 1 ] || [ "$fingerprint" != "$DOCKER_KEY_FINGERPRINT" ]; then
      rm -f "$key"
      die "Docker's signing key file holds $keys key(s), fingerprint '$fingerprint'; expected one, $DOCKER_KEY_FINGERPRINT: not installing"
    fi
    install -m 644 "$key" /etc/apt/keyrings/docker.asc
    rm -f "$key"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$ID" "${VERSION_CODENAME:?}" >/etc/apt/sources.list.d/docker.list
    apt_get update -q >/dev/null
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  fi
  # Log rotation for every container, so logs can't fill the disk.
  if [ ! -f /etc/docker/daemon.json ]; then
    install -d /etc/docker
    printf '{\n  "log-driver": "local",\n  "log-opts": { "max-size": "20m", "max-file": "5" },\n  "live-restore": true\n}\n' >/etc/docker/daemon.json
    systemctl restart docker 2>/dev/null || true
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  # The docker group is root-equivalent: this user can do anything Docker
  # can. docs/host.md, "One user or one per project".
  usermod -aG docker "$DEPLOY_USER"
fi

# -------------------------------------------------------------------- ssh

if [ "$DO_SSH" = true ]; then
  log "ssh hardening"
  root_login=prohibit-password
  [ -n "$ADMIN_USER" ] && root_login=no
  # 00- so it comes before cloud images' own drop-ins (sshd keeps the first
  # value it reads, and some images set PasswordAuthentication yes).
  conf=/etc/ssh/sshd_config.d/00-kit.conf
  install -d /etc/ssh/sshd_config.d
  grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config ||
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  cat >"$conf.new" <<EOF
# Written by deploy-kit host setup.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin $root_login
PubkeyAuthentication yes
MaxAuthTries 6
LoginGraceTime 30
X11Forwarding no

# The deploy user runs commands; it needs no agent, and no tunnel but the
# one Kamal opens back to a registry on the deploying machine (remote).
Match User $DEPLOY_USER
    AllowTcpForwarding remote
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
  mv "$conf.new" "$conf"
  install -d -m 755 /run/sshd # sshd -t needs it; absent until sshd first starts
  errors=$(mktemp)
  if sshd -t 2>"$errors"; then
    rm -f "$errors"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else
    cat "$errors" >&2
    rm -f "$errors" "$conf"
    die "the SSH configuration didn't validate: removed it, sshd unchanged"
  fi
  # What sshd uses isn't always what was written: it keeps the first value
  # it reads, so a line above the Include in sshd_config wins over ours.
  effective=$(sshd -T 2>/dev/null) || die "sshd -T failed: can't tell whether passwords are off"
  wrong=""
  for want in "passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin $root_login"; do
    got=$(printf '%s\n' "$effective" | awk -v k="${want%% *}" '$1 == k { print; exit }')
    # prohibit-password's older name, which sshd -T prints.
    [ "$got" != "permitrootlogin without-password" ] || got="permitrootlogin prohibit-password"
    # Not printed before OpenSSH 8.7 (challengeresponseauthentication then).
    [ -n "$got" ] || [ "${want%% *}" != kbdinteractiveauthentication ] || continue
    [ "$got" = "$want" ] || wrong="$wrong, ${got:-no ${want%% *}} (not ${want#* })"
  done
  [ -z "$wrong" ] ||
    die "sshd doesn't use what $conf says: ${wrong#, }. Another setting wins (above the Include in /etc/ssh/sshd_config, or in an earlier file of /etc/ssh/sshd_config.d/): remove it, then run this again"
fi

# --------------------------------------------------------------- firewall

if [ "$DO_FIREWALL" = true ]; then
  log "firewall"
  apt_install ufw
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  # SSH allowed, rate-limited only on request: `ufw limit` blocks an
  # address after 6 connections in 30 s, and Kamal opens one per command
  # (a group deploy checks health every 2 s): deploys were cut off half-way.
  ssh_rule=allow
  [ "$SSH_LIMIT" = true ] && ssh_rule=limit
  [ ${#SSH_FROM[@]} -eq 0 ] ||
    log "SSH only from ${SSH_FROM[*]}${SSH_CLIENT:+ (this connection comes from ${SSH_CLIENT%% *})}"
  # ssh_open PORT: SSH on PORT, from anywhere or from --ssh-allow-from only
  # (then an earlier run's rule for anywhere is removed).
  ssh_open() {
    local cidr rule
    if [ ${#SSH_FROM[@]} -eq 0 ]; then
      ufw "$ssh_rule" "$1/tcp" comment ssh >/dev/null
      return
    fi
    for cidr in "${SSH_FROM[@]}"; do
      ufw "$ssh_rule" proto tcp from "$cidr" to any port "$1" comment ssh >/dev/null
    done
    for rule in allow limit; do ufw delete "$rule" "$1/tcp" >/dev/null 2>&1 || true; done
  }
  ssh_open "$SSH_PORT"
  # The ports sshd really listens on, so enabling the firewall can't lock
  # you out when --ssh-port isn't one of them.
  for port in $(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'); do
    if [ "$port" != "$SSH_PORT" ]; then
      warn "sshd listens on $port, not only --ssh-port $SSH_PORT: allowing $port too"
      ssh_open "$port"
    fi
  done
  IFS=',' read -r -a ports <<<"$PORTS"
  for port in ${ports[@]+"${ports[@]}"}; do
    [ -n "$port" ] && ufw allow "$port/tcp" >/dev/null
  done
  ufw --force enable >/dev/null
fi

# --------------------------------------------------------------- upgrades

if [ "$DO_UPGRADES" = true ]; then
  log "unattended upgrades"
  apt_install unattended-upgrades
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    >/etc/apt/apt.conf.d/20auto-upgrades
fi

# ------------------------------------------------------------------- swap

if [ "$SWAP" != 0 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then
  log "swap $SWAP"
  if fallocate -l "$SWAP" /swapfile 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  else
    rm -f /swapfile
    warn "could not create swap (containers and some VPS types don't allow it)"
  fi
fi

# -------------------------------------------------------------- optionals

if [ "$DO_FAIL2BAN" = true ]; then
  log "fail2ban"
  apt_install fail2ban
  printf '[sshd]\nenabled = true\nport = %s\nbackend = systemd\n' "$SSH_PORT" >/etc/fail2ban/jail.d/kit-sshd.conf
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
fi

if [ "$DO_AGE" = true ]; then
  log "age key for $DEPLOY_USER"
  apt_install age
  home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
  keys="$home/.config/sops/age/keys.txt"
  if [ ! -f "$keys" ]; then
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$home/.config" "$home/.config/sops" "$home/.config/sops/age"
    runuser -u "$DEPLOY_USER" -- age-keygen -o "$keys" 2>/dev/null
    chmod 600 "$keys"
  fi
  printf 'age public key (add it to .sops.yaml): %s\n' "$(grep -m1 '^# public key:' "$keys" | cut -d' ' -f4)"
fi

log "done: deploy as $DEPLOY_USER (ssh: user: $DEPLOY_USER in config/deploy.yml)"
