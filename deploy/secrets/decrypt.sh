#!/usr/bin/env bash
# Decrypts every secrets/*.sops.env next to itself, on the server (the
# server's age key), before a deploy (deploy/server-sync.sh) or by hand.
# Each file is written next to the old one and swapped in only if every
# one decrypted, so a failure leaves the running configuration as it was.
#
# The files the containers get as `docker run --env-file`
# (deploy/kamal/*.yml, and offsite.env in backup/*.sh) are then checked:
# Docker takes a value literally, so KEY="value" would reach the app with
# its quotes. Compose's env files (db, stack, rabbitmq) strip them and
# aren't checked.
#
# Which files: the machine's deploy/.env names them (SECRETS="shadow
# shadow-db backup-receiver" on the shadow machine); unset, every one but
# the shadow machine's (the main VPS). Each machine holds a key only to its
# own files. deploy/.env is parsed, never sourced.
set -euo pipefail
cd "$(dirname "$0")"

only=""
if [ -f ../.env ]; then
  only=$(sed -n 's/^SECRETS=//p' ../.env | tail -n 1 | tr -d "\"'")
fi
if [ -n "$only" ]; then
  files=""
  for name in $only; do
    [ -f "$name.sops.env" ] || { echo "SECRETS in deploy/.env names $name, but there is no $name.sops.env: nothing changed" >&2; exit 1; }
    files="$files $name.sops.env"
  done
else
  files=""
  for f in *.sops.env; do
    case $f in shadow.sops.env | shadow-db.sops.env | backup-receiver.sops.env) continue ;; esac
    files="$files $f"
  done
fi

news=""
for f in $files; do
  [ -f "$f" ] || continue
  out="${f%.sops.env}.env"
  if ! (umask 077 && sops --decrypt --input-type dotenv --output-type dotenv "$f" >"$out.new"); then
    for n in $news "$out.new"; do rm -f "$n"; done
    echo "could not decrypt $f (is the server's age key in place?): nothing changed" >&2
    exit 1
  fi
  news="$news $out.new"
done

for f in app.env.new collector.env.new receiver.env.new shadow.env.new backup-receiver.env.new offsite.env.new; do
  [ -f "$f" ] || continue
  if grep -nE "^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[\"']" "$f" | cut -d= -f1 | grep .; then
    for n in $news; do rm -f "$n"; done
    echo "${f%.new}: the variables above have quoted values, which docker --env-file keeps as part of the value; remove the quotes (sops edit). Nothing changed." >&2
    exit 1
  fi
done

for n in $news; do mv "$n" "${n%.new}"; done
echo "secrets decrypted:$(for n in $news; do printf ' %s' "${n%.new}"; done)"
