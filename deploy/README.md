# Deploying

How the pieces in this folder fit together (project.md §15, §18, §19).
Development infrastructure is `compose.dev.yml`; everything else here is
production.

| File | What |
|---|---|
| `compose.single.yml` | Stage 1: the whole stack on one VPS |
| `compose.backup-receiver.yml` | Stage 2: a backup receiver on a second VPS |
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
3. Pull the images CI built (`docker compose -f compose.single.yml pull`), or
   build the database image here (`docker compose -f compose.single.yml
   build db`).
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

Migrations first, as their own step, and only expand-then-contract ones
(§15.3); then the role that changed:

    docker compose -f compose.single.yml pull
    docker compose -f compose.single.yml run --rm migrate
    docker compose -f compose.single.yml up -d web         # the site only
    docker compose -f compose.single.yml up -d collector   # tracking changes

Receivers, one at a time; the other keeps answering Kick:

    docker compose -f compose.single.yml up -d receiver-1
    docker compose -f compose.single.yml up -d receiver-2

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

To restore for real, stop the collector and web, then follow the same steps
as the restore test into the production volume (with `recovery_target_time`
set if you need a moment before a mistake).

## Monitoring (§18.2)

- The collector checks every minute and alerts through `ALERT_WEBHOOK_URL`
  or Telegram; the admin health page shows the open alerts.
- External checks, from a service off the VPS (e.g. healthchecks.io or
  UptimeRobot):
  - `https://$SITE_HOST/healthz` and `https://$INGRESS_HOST/health`;
  - `HEARTBEAT_URL` (the collector pings it every minute),
    `BACKUP_HEARTBEAT_URL` (daily) and `RESTORE_HEARTBEAT_URL` (weekly):
    set each to alert when the pings stop.
- Errors: `/admin/errors` (ErrorTracker); a new kind of error is alerted.

## Going live with the real Kick (phase 5, step 22)

Only after backups, alerts and the legal pages are in place, and the open
questions in project.md §16 that need the VPS are answered (v2 and Pusher
from a datacenter IP):

1. Run `mix record.probe` and `mix record.v2` from the VPS (sim/README.md).
2. Fill the real `KICK_*` values and `PUSHER_URL` in `secrets/app.env` and
   `secrets/receiver.env`; set `SITE_NAME` (no "Kick" in it) and
   `CONTACT_EMAIL`.
3. Add the first channels from `/admin/channels` and watch `/admin` for a
   day before announcing anything.
