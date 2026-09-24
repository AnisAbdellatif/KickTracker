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
| `Caddyfile` | HTTPS, the admin allowlist, the receivers' failover |
| `db/` | TimescaleDB with WAL-G (continuous backups) |
| `backup/` | Base backups and the scripted restore test |
| `ops/check-host.sh` | Disk and certificate checks |
| `rabbitmq/` | Topology and users; `make-prod-definitions.sh` for production |
| `secrets/` | sops-encrypted env files (see its README) |

## First deployment

On a fresh VPS with Docker, `sops` and `age`:

1. Clone the repository to `/srv/kick_tracker` and decrypt the secrets
   (`secrets/README.md`).
2. `./rabbitmq/make-prod-definitions.sh` with `secrets/rabbitmq.env` loaded
   (it writes `rabbitmq/definitions.prod.json`, git-ignored).
3. Pin the app image in `deploy/.env` (git-ignored; the deploy workflow
   keeps it up to date afterwards), then pull the images CI built, or
   build the database image here (`docker compose -f compose.single.yml
   build db`):

       echo "APP_IMAGE=ghcr.io/<owner>/kicktracker-app:<sha>" >> .env
       echo "COLLECTOR_IMAGE=ghcr.io/<owner>/kicktracker-app:<sha>" >> .env
       docker compose -f compose.single.yml pull
4. Start the database and the queue, then migrate:

       docker compose -f compose.single.yml up -d db rabbitmq
       docker compose -f compose.single.yml run --rm migrate

5. Start everything: `docker compose -f compose.single.yml up -d`.
6. Take the first base backup (`./backup/base-backup.sh`) and install the
   cron lines from `backup/base-backup.sh`, `backup/restore-test.sh` and
   `ops/check-host.sh`.
7. Invite the first admin and open the link from an allowed network:

       docker compose -f compose.single.yml exec web /app/bin/invite you@example.org

8. Point the Kick app's webhook URL (in Kick's developer settings) at
   `https://$INGRESS_HOST/`.

## Deploying a change

Use the Deploy workflow (`.github/workflows/deploy.yml`); by hand it does
this. Migrations first, as their own step, and only expand-then-contract
ones (§15.3); each statement waits at most 5s for a lock. Then the role
that changed, with its image pinned in `deploy/.env`:

    docker compose -f compose.single.yml run --rm migrate
    docker compose -f compose.single.yml up -d --no-deps web   # the site only

Collectors (§10.1): two run, one collects. Update the **standby first**,
wait for it to be healthy, then the leader: its clean stop releases the
lease and the updated standby collects within a second. Which one leads:

    docker compose -f compose.single.yml exec collector-a curl -s http://127.0.0.1:4101/status

    docker compose -f compose.single.yml up -d --no-deps collector-b   # the standby
    docker compose -f compose.single.yml up -d --no-deps collector-a   # then the leader

A plain `docker compose up -d` leaves the collectors alone unless
`COLLECTOR_IMAGE` or their settings changed.

Receivers, one at a time; the other keeps answering Kick:

    docker compose -f compose.single.yml up -d receiver-1
    docker compose -f compose.single.yml up -d receiver-2

## The shadow collector (§10.5)

An independent collector on a second machine (the stage 2 one), with its
own database, collecting the same channels all the time. When the main VPS
is down, it keeps polling and chatting; when the main VPS is back, the
primary side fills what it missed from the shadow's database, every 5
minutes, for the last `BACKFILL_DAYS` (7).

1. Link the two machines privately (WireGuard or Tailscale) and set
   `PRIVATE_IP` in each `deploy/.env` to that machine's private address:
   each database is then published on it (main on 5432, shadow on 5433),
   and on nothing public.
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
  database and that recent streams' figures agree with their samples.
  A failure is sent to `ALERT_WEBHOOK_URL`; success pings
  `RESTORE_HEARTBEAT_URL`.
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
