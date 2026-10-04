# Secrets

Encrypted with [sops](https://github.com/getsops/sops) and
[age](https://github.com/FiloSottile/age) (project.md §19.3). Only the
`*.sops.env` files are committed; the decrypted `*.env` files are
git-ignored and live only on the server.

| File | Used by | Holds |
|---|---|---|
| `stack.env` | The bundled Caddy, `ops/check-host.sh` (which parses it, never sources it) | `SITE_HOST`, `INGRESS_HOST`, `ACME_EMAIL`, `ADMIN_ALLOW` (with the host's own Caddy, only the hosts are read) |
| `app.env` | web, migrate | see `app.env.example` |
| `collector.env` | both collectors | see `collector.env.example` (no web secrets) |
| `shadow.env`, `shadow-db.env` | the shadow machine: its collector (`kamal/shadow.yml`) and its database (`compose.shadow.yml`) | see their examples |
| `backup-receiver.env` | the shadow machine's backup receiver (`kamal/backup-receiver.yml`) | see `backup-receiver.env.example` |
| `receiver.env` | both receivers | see `receiver.env.example` |
| `deployer.env` | the machine that deploys (Kamal's registry login) | see `deployer.env.example` |
| `db.env` | the database and the backups (`backup/*.sh` also read `POSTGRES_*`, `WALG_*`, `AWS_*` and the backup heartbeat URLs here) | see `db.env.example` |
| `offsite.env` | `backup/offsite-sync.sh` and `backup/restore-test.sh` (passed to rclone as `docker run --env-file`: no quotes) | the Filen account the backups are mirrored to, the folder, `OFFSITE_HEARTBEAT_URL`; see `offsite.env.example` |
| `rabbitmq.env` | `rabbitmq/make-prod-definitions.sh` | the five RabbitMQ passwords |

## First time

1. Make an age key on the server and on each admin's machine:
   `age-keygen -o ~/.config/sops/age/keys.txt`, and put the public keys in
   `../../.sops.yaml` (then `sops updatekeys` each `*.sops.env`, so the
   new key can read them).
2. Copy each `*.example` to its name without `.example`, fill it in, and
   encrypt it: `sops --encrypt app.env > app.sops.env`.
   A setting left empty (`HEARTBEAT_URL=`) counts as not set. `app.env`
   and `collector.env` each need the Kick credentials and `PUSHER_URL`:
   the collectors are what talk to Kick.
3. Commit only the `*.sops.env` files.

## On the server

Before each deploy the kit runs `deploy/server-sync.sh` there, which runs
`decrypt.sh`: the machine's `*.sops.env` decrypted with its age key,
swapped in only if all of them decrypted. Which are the machine's: those
named by `SECRETS` in its `deploy/.env` (the shadow machine: `SECRETS="shadow
shadow-db backup-receiver"`), or, unset, all but those three (the main
VPS). The shadow machine's files are encrypted to its key and the admins'
only (`../../.sops.yaml`'s first rule), the others never to its key. By
hand:

    deploy/secrets/decrypt.sh

`app.env`, `collector.env`, `receiver.env`, `shadow.env` and
`backup-receiver.env` reach the containers as
`docker run --env-file` (deploy/kamal/*.yml), which takes values
literally: `KEY="value"` would keep its quotes. `decrypt.sh` refuses such
values and changes nothing; remove the quotes (`sops app.sops.env`).

Rotate a secret by editing it in place (`sops app.sops.env`), committing,
and deploying: the deploy decrypts it on the server, and the containers
that read it are replaced (a secret only the collectors read: `kit group
deploy collectors`).

## On the machine that deploys

`deployer.sops.env` (from `deployer.env.example`) holds `GHCR_READ_TOKEN`,
a GitHub token (classic) with only `read:packages`, which Kamal logs the
server in to GHCR with at each deploy (`deploy/kamal/registry-password`).
The app's secrets never need decrypting there.
