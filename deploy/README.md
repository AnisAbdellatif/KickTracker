# Deploying

How the pieces in this folder fit together (project.md §15, §18, §19).
Development infrastructure is `compose.dev.yml`; everything else here is
production.

| File | What |
|---|---|
| `compose.single.yml` | Stage 1: the whole stack on one VPS |
| `compose.backup-receiver.yml` | Stage 2: a backup receiver on a second VPS |
| `compose.shadow.yml` | Stage 2: the shadow collector on the second VPS (§10.5) |
| `shadow/readers.sql` | Read-only users for the primary / shadow pair |
| `Caddyfile` | The bundled Caddy (profile `caddy`): HTTPS, from `caddy/sites.caddy` |
| `caddy/sites.caddy` | The sites: the admin allowlist, the web pair, the receivers' failover; imported by the bundled Caddy or the host's own |
| `caddy/backup-receiver.caddy` | The stage 2 backup receiver's Caddy (a Cloudflare origin certificate) |
| `db/` | TimescaleDB with WAL-G (continuous backups) |
| `backup/` | Base backups and the scripted restore test |
| `ops/check-host.sh` | Disk and certificate checks |
| `ops/common.sh` | Shared by the cron scripts: reading the secrets, alerts, heartbeats |
| `rabbitmq/` | Topology and users; `make-prod-definitions.sh` for production |
| `secrets/` | sops-encrypted env files (see its README) |

## First deployment

On a fresh VPS with Docker, `sops` and `age`:

1. As the user that will deploy (in the `docker` group), give the server
   read access to GitHub and clone the repository to `/srv/kick_tracker`,
   then decrypt the secrets (`secrets/README.md`):
   - git: a read-only **deploy key** (`ssh-keygen -t ed25519`, its
     `~/.ssh/id_ed25519.pub` added under the repository's Settings,
     Deploy keys, write access off), and clone over SSH
     (`git@github.com:<owner>/<repo>.git`) so the `git pull` of every
     deploy needs no password. A public repository can be cloned over
     HTTPS with no credentials instead.
   - images: `docker login ghcr.io -u <GitHub user>` with a personal
     access token (classic) that has only `read:packages`; Docker keeps it
     in `~/.docker/config.json` for every later pull. Not needed if the
     packages are public.
2. `./rabbitmq/make-prod-definitions.sh` with `secrets/rabbitmq.env` loaded
   (it writes `rabbitmq/definitions.prod.json`, git-ignored).
3. Pin the app image in `deploy/.env` (git-ignored; the deploy workflow
   keeps it up to date afterwards), then pull the images CI built, or
   build the database image here (`docker compose -f compose.single.yml
   build db`):

       echo "APP_IMAGE=ghcr.io/<owner>/kicktracker-app:<sha>" >> .env
       echo "COLLECTOR_IMAGE=ghcr.io/<owner>/kicktracker-app:<sha>" >> .env
       docker compose -f compose.single.yml pull
4. Choose what serves HTTPS. A VPS with no web server of its own uses the
   bundled Caddy: `echo COMPOSE_PROFILES=caddy >> .env`. A VPS whose host
   already runs Caddy for something else keeps it, and imports our sites
   into it (below, "A Caddy already on the host").
5. Start the database and the queue, then migrate:

       docker compose -f compose.single.yml up -d db rabbitmq
       docker compose -f compose.single.yml run --rm migrate

6. Start everything: `docker compose -f compose.single.yml up -d`.
7. Take the first base backup (`./backup/base-backup.sh`) and install the
   cron lines from `backup/base-backup.sh`, `backup/restore-test.sh` and
   `ops/check-host.sh` in the deploy user's crontab (`crontab -e`: the
   decrypted secrets are readable by that user only).
8. Invite the first admin and open the link from an allowed network:

       docker compose -f compose.single.yml exec web-a /app/bin/invite you@example.org

9. Point the Kick app's webhook URL (in Kick's developer settings) at
   `https://$INGRESS_HOST/`.

## A Caddy already on the host

When the host already runs Caddy (for another site), ours isn't started
(no `caddy` profile) and the host's serves both. Each web node and
receiver is published on loopback for it: `web-a` on 127.0.0.1:4110,
`web-b` on 4111, `receiver-1` on 4160, `receiver-2` on 4161 (set
`WEB_A_PORT`, `WEB_B_PORT`, `RECEIVER_1_PORT`, `RECEIVER_2_PORT` in
`deploy/.env` if one is taken). Add one line to the host's Caddyfile
(`/etc/caddy/Caddyfile` for the packaged Caddy), outside any site block:

    import /srv/kick_tracker/deploy/caddy/sites.caddy stats.example.org ingress.example.org 127.0.0.1:4110 127.0.0.1:4111 127.0.0.1:4160 127.0.0.1:4161 100.64.0.0/10

The arguments: the site's host, the ingress host, the two web nodes, the
two receivers, then the networks allowed on `/admin` (one or more CIDRs,
as `ADMIN_ALLOW`). Then `caddy validate --config /etc/caddy/Caddyfile`
and `systemctl reload caddy`. The host's Caddy gets the certificates with
its own ACME email; `secrets/stack.env` is then read only by
`ops/check-host.sh` (the hosts whose certificates it checks).

The sites stay in git: after a `git pull` that changes
`caddy/sites.caddy`, reload the host's Caddy. The Caddy user must be able
to read the file (it is world-readable in a normal checkout).

If the host's Caddy runs in a container instead, it can't reach the host's
loopback: give it `network_mode: host`, or attach it to this stack's
network (`kicktracker_default`) and pass `web-a:4100 web-b:4100
receiver-1:4060 receiver-2:4060` as the upstreams.

If Cloudflare (or another proxy) is in front of the host's Caddy, set
`TRUSTED_PROXY_HOPS=2` in `secrets/app.env`, or every visitor shares the
proxy's address for the rate limits.

## Deploying a change

Merge to `main`. CI runs the checks, builds the images, then deploys them:
the `deploy` job in `.github/workflows/ci.yml` runs `release.sh` on the
server over SSH, which pulls, decrypts the secrets, and deploys the
collectors, web and the receivers in turn with `deploy.sh`. A step that
fails stops the release and the job goes red; what wasn't reached keeps
running the previous version.

It needs, once:

- in GitHub (Settings, Secrets and variables, Actions; the repository's
  or the `production` environment's): the secrets `DEPLOY_SSH_KEY` (a key
  only for deploying, its public half in that user's
  `~/.ssh/authorized_keys`) and `DEPLOY_KNOWN_HOSTS` (`ssh-keyscan
  <host>`), and `DEPLOY_HOST` and `DEPLOY_USER`, as secrets or variables.
  Without them the job skips with a notice;
- the repository variable `DEPLOY_DIR` if the checkout isn't in
  `/srv/kick_tracker` (e.g. `/opt/kick_tracker`); the paths in this file
  and in the cron lines of `backup/` and `ops/` are then that directory;
- on the server, as that user: the checkout in `DEPLOY_DIR` able to
  `git pull` without a prompt and `docker login ghcr.io` done (both in
  "First deployment", step 1), `sops` installed and the server's age key
  in `~/.config/sops/age/keys.txt`.

To stop deploying on merge, set the repository variable `AUTO_DEPLOY` to
`false` (Settings, Secrets and variables, Actions, Variables).

By hand, from the checkout (the same as CI):

    git pull && deploy/release.sh

or one role from `deploy/`: `ROLE=collector ./deploy.sh` (or `web`,
`receivers`). The Deploy workflow does either from GitHub (`all` or a
role). Each deploys the images CI built from the checkout's commit (they
are tagged with the `main` commit they were built from). `TAG=<sha>`
deploys another build, e.g. to roll back; `APP_IMAGE` / `RECEIVER_IMAGE`
name an image outright. An image that doesn't exist yet (CI still
building) stops the script before anything changes. A change to
`caddy/sites.caddy` also needs the host's Caddy reloaded, by hand.

Migrations run first, as their own step, and only expand-then-contract
ones (§15.3); each statement waits at most 5s for a lock. Then the pair
is updated one at a time, each waiting for the other to be healthy:
`web-a` then `web-b` (Caddy sends visitors to whichever answers); the
collectors' **standby first**, then the leader, whose clean stop hands
collection over within a second; `receiver-1` then `receiver-2`. Images
are pinned in `deploy/.env`, so a plain `docker compose up -d` never
swaps one by accident. A rollback is the same command with `TAG=` the previous sha.

Which collector leads:

    docker compose -f compose.single.yml exec collector-a curl -s http://127.0.0.1:4101/status

Before trusting a change to any of this, rehearse it on a development
machine: `rehearsal/rehearse.sh` (rehearsal/README.md).

## The backup receiver (stage 2, §15.2)

A second receiver on the stage 2 machine takes webhooks while the main VPS
is down, spools them, and forwards them to the main RabbitMQ once it
answers again (`compose.backup-receiver.yml`).

1. Link the two machines privately (WireGuard or Tailscale) and set
   `PRIVATE_IP` in the main VPS's `deploy/.env` to its private address,
   then `docker compose -f compose.single.yml up -d rabbitmq`: AMQP (5672)
   is then published on that address only (loopback while it is unset).
   AMQP is plain here, the tunnel is what encrypts it, so never set
   `PRIVATE_IP` to a public address. Docker's published ports bypass
   `ufw`: allow only the backup machine's private address, with the
   tunnel's own rules (Tailscale ACLs, WireGuard `AllowedIPs`) or an
   `iptables -I DOCKER-USER` rule.
2. On the backup machine, `secrets/receiver.env` from its example with
   `AMQP_URL=amqp://receiver:<password>@<main private address>:5672`,
   and `secrets/stack.env` with `INGRESS_HOST`.
3. Certificates: Cloudflare's load balancer sends the ingress host to the
   main VPS while it is healthy, so an ACME challenge for it never reaches
   the backup machine and Caddy can't get a public certificate there.
   Create a Cloudflare Origin CA certificate for the ingress host
   (Cloudflare dashboard, SSL/TLS, Origin Server) and save it as
   `secrets/origin-cert.pem` and its key as `secrets/origin-key.pem`
   (git-ignored; `chmod 600` the key). Set the zone's SSL mode to
   "Full (strict)". The main VPS keeps its public certificate (Caddy
   renews it a month ahead, so a renewal missed during a failover is
   retried); it may use the same origin certificate instead.
4. `docker compose -f compose.backup-receiver.yml up -d`, then add both
   machines to the Cloudflare load balancer's pool for the ingress host,
   with a monitor on `https://<ingress host>/health`.

## The shadow collector (§10.5)

An independent collector on a second machine (the stage 2 one), with its
own database, collecting the same channels all the time. When the main VPS
is down, it keeps polling and chatting; when the main VPS is back, the
primary side fills what it missed from the shadow's database, every 5
minutes, for the last `BACKFILL_DAYS` (7).

1. Link the two machines privately (WireGuard or Tailscale) and set
   `PRIVATE_IP` in each `deploy/.env` to that machine's private address:
   each database is then published on it (main on 5432, shadow on 5433),
   and on nothing public (the main VPS's RabbitMQ too, on 5672, for the
   backup receiver).
2. Register a second app on kick.com for the shadow (its own token and rate
   limits).
3. On the shadow machine: `secrets/shadow.env` and `secrets/shadow-db.env`
   from their examples, `SHADOW_IMAGE` pinned in `deploy/.env`, then

       docker compose -f compose.shadow.yml up -d db
       docker compose -f compose.shadow.yml run --rm migrate
       docker compose -f compose.shadow.yml up -d

4. Create the read-only users (`shadow/readers.sql`): `shadow_reader` on
   the main database, `backfill_reader` on the shadow's. Set
   `MAIN_DATABASE_URL` in `shadow.env` and `SHADOW_DATABASE_URL` in
   `collector.env`, and redeploy the collectors.
5. Set the shadow's own `HEARTBEAT_URL`, and alerts (it tells you when it
   can't reach the main VPS; the main side's alerts may be down with it).

Deploy it with the Deploy workflow's `shadow` target (standby first, like
the main collectors). The health page shows it as "shadow, on another
machine", and an alert fires when it hasn't been seen collecting for 15
minutes. It keeps `SHADOW_KEEP_DAYS` (30) of data and isn't backed up: its
data only matters until the main side has filled its gaps.

## Backups (§18.1)

- WAL is archived continuously by the database (`db/archive.conf`): at most
  a minute is lost.
- `backup/base-backup.sh`, daily: a full base backup and pruning (keeps 7).
- `backup/restore-test.sh`, weekly: restores the latest backup into a
  scratch container, replays the WAL, checks row counts against the live
  database (the stack's `db`, through `docker compose exec`, when it runs
  on the same host; or `LIVE_DATABASE_URL`) and that recent streams'
  figures agree with their samples.
- Both run from the deploy user's crontab (the cron lines are at the top
  of each script) and need nothing from cron's environment: they read
  `secrets/db.env` (WAL-G's storage, `POSTGRES_USER`/`POSTGRES_DB`,
  `BACKUP_HEARTBEAT_URL`, `RESTORE_HEARTBEAT_URL`) and the alert settings
  of `secrets/collector.env` (or `app.env`). Any failure, expected or not,
  is sent to `ALERT_WEBHOOK_URL` and/or Telegram; each success pings its
  heartbeat URL, so a job that stops running is noticed too.
  `ops/check-host.sh` reads its settings the same way.
- Also keep: `deploy/` (in git), the RabbitMQ definitions (regenerated from
  secrets), and the age private keys (offline). Receiver spools are
  short-lived and not backed up.

Each collector's journal (`journal-a`, `journal-b`) holds writes only
until the database has them, and isn't backed up; don't delete a volume
whose collector reports writes waiting (health page).

To restore for real, stop both collectors and web, then follow the same steps
as the restore test into the production volume (with `recovery_target_time`
set if you need a moment before a mistake).

## Monitoring (§18.2)

- Alerts are checked every minute by the collecting node **and** by web
  (so a dead collector is noticed), and sent through `ALERT_WEBHOOK_URL`
  or Telegram; the admin health page shows the open alerts and each
  collector: collecting or standing by, writes waiting, recent handoffs.
- Each collector's container healthcheck asks its own status port
  (`docker compose ps` shows it).
- External checks, from a service off the VPS (e.g. healthchecks.io or
  UptimeRobot):
  - `https://$SITE_HOST/healthz` and `https://$INGRESS_HOST/health`;
  - `HEARTBEAT_URL` (the collecting node pings it every minute: set it),
    `BACKUP_HEARTBEAT_URL` (daily) and `RESTORE_HEARTBEAT_URL` (weekly):
    set each to alert when the pings stop.
- Errors: `/admin/errors` (ErrorTracker); a new kind of error is alerted.

## Going live with the real Kick (phase 5, step 22)

Only after backups, alerts and the legal pages are in place, and the open
questions in project.md §16 that need the VPS are answered (v2 and Pusher
from a datacenter IP):

1. Run `mix record.probe` and `mix record.v2` from the VPS (sim/README.md).
2. Fill the real `KICK_*` values and `PUSHER_URL` in `secrets/app.env`,
   `secrets/collector.env` and `secrets/receiver.env`; set `SITE_NAME` (no "Kick" in it) and
   `CONTACT_EMAIL`.
3. Add the first channels from `/admin/channels` and watch `/admin` for a
   day before announcing anything.
