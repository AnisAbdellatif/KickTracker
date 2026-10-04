# Deploying

How the pieces in this folder fit together (project.md §15, §18, §19).
Development infrastructure is `compose.dev.yml`; everything else here is
production.

The main VPS runs two kinds of containers:

- **the app's** (two web nodes, two collectors, two webhook receivers),
  deployed with [deploy-kit](https://github.com/AnisAbdellatif/deploy-kit)
  and [Kamal](https://kamal-deploy.org) from your machine
  (`release.sh`), each pair one at a time;
- **the infrastructure's** (TimescaleDB, RabbitMQ, the bundled Caddy),
  with compose (`compose.single.yml`), rarely touched.

Both are on one Docker network, `kamal`. CI builds, labels and attests the
images; it deploys nothing and holds no key to the server.

| File | What |
|---|---|
| `release.sh` | **A release**, from your machine: `kit deploy` of the groups the release changes, the app's then the receivers' |
| `kamal/app.yml`, `kamal/receiver.yml` | Kamal's configs: the app image (web, collectors) and the receiver image |
| `kamal/*.sandbox.yml` | Kamal's `sandbox` destination: the stack on this machine (`kit sandbox`) |
| `kamal/registry-password` | The read-only GHCR token Kamal logs the server in with |
| `server-sync.sh` | Run on the server before each deploy: checkout up to the commit, secrets decrypted |
| `../.kamal/` | deploy-kit: its settings (`kit.env`), the groups (`groups/`), the project's steps (`steps/`), the vendored kit (`kit/`) |
| `compose.single.yml` | Stage 1 infrastructure: database, queue, bundled Caddy |
| `shadow.sh` | **Deploys the shadow machine** (the shadow collector and the backup receiver), by hand at any time |
| `shadow-follow.sh` | The follower on the shadow machine: deploys what the main VPS runs once it has been live and healthy there for `KT_SHADOW_SOAK` (6h) |
| `kamal/shadow.yml`, `kamal/backup-receiver.yml` | Kamal's configs for the shadow machine: one shadow collector, one backup receiver |
| `compose.shadow.yml` | The shadow machine's database |
| `shadow/readers.sql` | Read-only users for the primary / shadow pair |
| `shadow/kicktracker-follow.*` | The follower's systemd timer on the shadow machine |
| `Caddyfile` | The bundled Caddy (profile `caddy`): HTTPS, from `caddy/sites.caddy` |
| `caddy/sites.caddy` | The sites: the admin allowlist, the web pair, the receivers' failover; imported by the bundled Caddy or the host's own |
| `db/` | TimescaleDB with WAL-G (continuous backups) |
| `backup/` | Base backups and the scripted restore test |
| `ops/check-host.sh` | Disk and certificate checks |
| `ops/common.sh` | Shared by the cron scripts: reading the secrets, alerts, heartbeats |
| `rabbitmq/` | Topology and users; `make-prod-definitions.sh` for production |
| `secrets/` | sops-encrypted env files, and `decrypt.sh` (see its README) |
| `compose.sandbox.yml` | The sandbox's differences from `compose.single.yml` (plain HTTP on 127.0.0.1:8080) |
| `rehearsal/` | The whole deploy path, rehearsed on the sandbox under load |

## First deployment

On a fresh VPS with Docker, `sops` and `age` (deploy-kit's host setup
does Docker, the deploy user, SSH hardening and the firewall:
`.kamal/kit/bin/kit host remote root@<host> …`):

1. As the user that will deploy (in the `docker` group), give the server
   read access to GitHub and clone the repository to `/srv/kick_tracker`
   (the cron scripts, compose files, Caddy's sites and the encrypted
   secrets live in this checkout; `server-sync.sh` keeps it up to date at
   each deploy):
   - a read-only **deploy key** (`ssh-keygen -t ed25519`, its
     `~/.ssh/id_ed25519.pub` added under the repository's Settings,
     Deploy keys, write access off), and clone over SSH
     (`git@github.com:<owner>/<repo>.git`) so `git fetch` needs no
     password. A public repository can be cloned over HTTPS instead.
   - `sops` installed and the server's age key in
     `~/.config/sops/age/keys.txt`; then `secrets/decrypt.sh`
     (`secrets/README.md`).
2. `./rabbitmq/make-prod-definitions.sh` with `secrets/rabbitmq.env` loaded
   (it writes `rabbitmq/definitions.prod.json`, git-ignored).
3. Choose what serves HTTPS. A VPS with no web server of its own uses the
   bundled Caddy: `echo COMPOSE_PROFILES=caddy >> .env` in `deploy/`. A
   VPS whose host already runs Caddy for something else keeps it, and
   imports our sites into it (below, "A Caddy already on the host").
4. Kamal's network, then the infrastructure (the database image is built
   here, or pulled: `DB_IMAGE` in `deploy/.env`):

       docker network create kamal
       docker compose -f compose.single.yml up -d --wait db rabbitmq

5. On **your machine**, in a checkout of `main`:
   - `.kamal/kit.local.env` from its example: the server (`KT_HOST`), the
     deploy user (`KT_SSH_USER`), the checkout (`KT_DEPLOY_DIR`), the smoke
     URLs and where the kit's notifications go;
   - `secrets/deployer.sops.env` from `deployer.env.example`: a GitHub
     token (classic) with only `read:packages`, encrypted like the others;
   - Kamal (`gem install kamal`, 2.12 or later), `sops`, `gh` logged in
     (for the CI and attestation checks), and Docker with its buildx
     plugin (the attestation gate resolves each image to a digest with
     `docker buildx imagetools inspect`, and refuses without it). Or only Docker: with
     `KIT_RUNNER=docker` in `.kamal/kit.local.env` the kit runs Kamal, sops
     and gh in its own image, handing it your SSH keys, gh's token and age
     key (deploy-kit's `docs/runner.md`).
6. The first deploy (collectors with `--bootstrap`: nobody collects yet),
   then the receivers:

       .kamal/kit/bin/kit deploy --bootstrap
       .kamal/kit/bin/kit deploy -c deploy/kamal/receiver.yml

   With the bundled Caddy: `docker compose -f compose.single.yml up -d caddy`.
7. Take the first base backup (`./backup/base-backup.sh`), copy it off the
   VPS once by hand (`./backup/offsite-sync.sh`, with `offsite.sops.env`
   filled in: see Backups below) and install the cron lines from
   `backup/base-backup.sh`, `backup/offsite-sync.sh`,
   `backup/restore-test.sh` and `ops/check-host.sh` in the deploy user's
   crontab (`crontab -e`: the decrypted secrets are readable by that user
   only). Without the crontab there are no base backups and no disk or
   archiving alerts.
8. Invite the first admin and open the link from an allowed network:

       docker exec $(docker ps -q --filter label=role=web_a) /app/bin/invite you@example.org

9. Point the Kick app's webhook URL (in Kick's developer settings) at
   `https://$INGRESS_HOST/`.

## A Caddy already on the host

When the host already runs Caddy (for another site), ours isn't started
(no `caddy` profile) and the host's serves both. Each web node and
receiver publishes its port on loopback for it: `web_a` on 127.0.0.1:4110,
`web_b` on 4111, `receiver_1` on 4160, `receiver_2` on 4161 (set
`KT_WEB_A_PORT`, `KT_WEB_B_PORT`, `KT_RECEIVER_1_PORT`, `KT_RECEIVER_2_PORT`
in `.kamal/kit.local.env` if one is taken). Add one line to the host's
Caddyfile (`/etc/caddy/Caddyfile` for the packaged Caddy), outside any
site block:

    import /srv/kick_tracker/deploy/caddy/sites.caddy stats.example.org ingress.example.org 127.0.0.1:4110 127.0.0.1:4111 127.0.0.1:4160 127.0.0.1:4161 100.64.0.0/10

The arguments: the site's host, the ingress host, the two web nodes, the
two receivers, then the networks allowed on `/admin` (one or more CIDRs,
as `ADMIN_ALLOW`). Then `caddy validate --config /etc/caddy/Caddyfile`
and `systemctl reload caddy`. The host's Caddy gets the certificates with
its own ACME email; `secrets/stack.env` is then read only by
`ops/check-host.sh` (the hosts whose certificates it checks).

The sites stay in git: after a deploy that changes `caddy/sites.caddy`
(the server's checkout is brought up to the commit), reload the host's
Caddy. The Caddy user must be able to read the file (it is
world-readable in a normal checkout).

If the host's Caddy runs in a container instead, it can't reach the host's
loopback: give it `network_mode: host`, or attach it to the `kamal`
network and pass `web-a:4100 web-b:4100 receiver-1:4060 receiver-2:4060`
as the upstreams (the containers' network aliases, which follow each
deploy).

If Cloudflare (or another proxy) is in front of the host's Caddy, set
`TRUSTED_PROXY_HOPS=2` in `secrets/app.env`, or every visitor shares the
proxy's address for the rate limits.

## Deploying a change

Merge to `main` and wait for CI to pass (its Images job builds, labels and
attests the app, receiver and database images, tagged with the commit).
Then, from your machine, in an up-to-date checkout of `main`:

    deploy/release.sh --dry-run   # what would be deployed, and why
    deploy/release.sh

Only the groups the release changes are deployed. For each group the
script compares the build it runs (the active collector's, for the
collectors) with this commit, over the paths that group runs: its image's
build context, its Kamal config and its secrets file, and for the
collectors minus what only web nodes run (the list is in the script). A
web-only change deploys the web nodes and leaves collection and the
receivers alone; tests and docs deploy nothing. `--all` deploys every
group regardless. `deploy/release-test.sh` (run by CI) checks which
groups each kind of change deploys; add to it when the lists change.
The kit lets the environment win over `.kamal/`'s files, so `release.sh`
refuses to run while a `KT_*` variable is exported in the shell (it would
replace the server's settings), and lists any `KIT_*` one it will use.

That is up to two `kit deploy --group …`s (deploy-kit, `.kamal/`): the
app's Kamal config, then the receivers'. Before anything is replaced, the
kit checks that you're on `main`, clean and pushed, that CI passed for
this exact commit and that the images carry the CI workflow's
attestation; then it brings the server's checkout up to the commit and
decrypts its secrets there (`server-sync.sh`), and, when the app's config
is deployed, runs the migrations (`.kamal/steps/migrate`: the new image's
`bin/migrate`, expand-then-contract only, `lock_timeout 5s`; a migration
is app code, so it deploys the collectors and web both). Then, one group
at a time (`.kamal/groups/`):

- **collectors**: only the standby gets the new build (stopped first,
  never two containers on one journal), then the leader restarts in place
  on the build it had and its clean stop hands collection over within a
  second. The old leader stays on the previous build as the standby.
- **web**: `web_a`, then `web_b`, each stopped, replaced and healthy
  before the next (Caddy sends visitors to whichever answers). One that
  fails its new build goes back to its previous one.
- **receivers**: `receiver_1`, then `receiver_2`, the same way.

Last, the smoke tests (`KIT_SMOKE_URLS`) through Caddy: if they fail, what
the release deployed is rolled back (web and receivers to their previous
build, each stopped first; the collectors switched back). A step that fails stops the release; what
wasn't reached keeps running the previous build. Every outcome goes to the
kit's notification channels.

Only `kit` deploys these containers: a plain `kamal deploy` that would put
both collectors on one build is refused by the kit's role guard.

One part at a time, and rollbacks:

    .kamal/kit/bin/kit group deploy web                  # this checkout's commit
    .kamal/kit/bin/kit group deploy web -- --version <sha>  # another build (a rollback)
    .kamal/kit/bin/kit group switch collectors           # collectors: back to the standby (a second, nothing pulled)
    .kamal/kit/bin/kit group status                      # versions, health, who collects
    .kamal/kit/bin/kit freeze "reason" / unfreeze        # stop deploys for a while

`kit group switch collectors` again goes forward; the next collector
deploy updates whichever one stands by. `release.sh --version <sha>`
redeploys another commit's images everywhere.

Images are named by commit, so a deploy never swaps an image by accident;
`kamal app version -c deploy/kamal/app.yml` shows what runs (with
`.kamal/kit.local.env` exported, or through `kit`). A change to
`caddy/sites.caddy` also needs the host's Caddy reloaded, by hand.

## The sandbox, and the rehearsal

To try the deploy path on your machine, with the stack as production runs
it and the fake Kick in place of kick.com, use the sandbox (deploy-kit's
`kit sandbox`, set up in `../.kamal/sandbox/`, whose README says what is
where):

    .kamal/kit/bin/kit sandbox up       # the working tree built and deployed; http://localhost:8080
    .kamal/kit/bin/kit sandbox deploy   # again, after a change
    .kamal/kit/bin/kit sandbox reset    # gone, data included

Before trusting a change to any of this, rehearse it: `rehearsal/rehearse.sh`
(rehearsal/README.md) runs the sandbox under load through every kind of
deploy, restart and rollback, and reports what each cost.

## Moving the running server from compose to Kamal (once)

The main VPS ran every container with compose until the switch to
deploy-kit. The move, without a gap in collection or webhook intake:

1. On the server, `git pull` (for `server-sync.sh`, the new
   `compose.single.yml` and `secrets/decrypt.sh`), then
   `secrets/decrypt.sh`: it refuses quoted values in `app.env`,
   `collector.env` and `receiver.env` (Docker's `--env-file` would keep
   the quotes); fix any with `sops` first.
2. `docker network create kamal`, and attach the running infrastructure to
   it without restarting it:

       docker network connect --alias db kamal kicktracker-db-1
       docker network connect --alias rabbitmq kamal kicktracker-rabbitmq-1
       # with the bundled Caddy:
       docker network connect --alias caddy kamal kicktracker-caddy-1

   (The next `docker compose up` of the infrastructure recreates them on
   `kamal` alone: plan that restart like any database restart.)
3. The web nodes, one at a time (compose's and Kamal's share ports, and
   Caddy sends visitors to whichever answers):

       docker stop kicktracker-web-b-1
       .kamal/kit/bin/kit group deploy web --role web_b
       docker stop kicktracker-web-a-1
       .kamal/kit/bin/kit group deploy web --role web_a

   The receivers the same way, `receiver-2` / `receiver_2` first (Caddy
   sends webhooks to receiver-1 while it answers), with
   `kit group deploy receivers --role …`. Each Kamal receiver takes over
   its compose twin's spool volume, so spooled webhooks are forwarded.
4. The collectors: stop the compose collector standing by
   (`docker stop kicktracker-collector-b-1` if `collector-a` leads; the
   health page says which), and start its Kamal twin on the same journal
   volume, standing by:

       .kamal/kit/bin/kit group deploy collectors --bootstrap --role collector_b

   When it's healthy, stop the compose leader (`docker stop -t 60
   kicktracker-collector-a-1`): its clean stop hands the lease to
   `collector_b`. Then `… --bootstrap --role collector_a`, and
   `kit group status collectors` shows one collecting, one standing by.
5. Remove the stopped compose containers, check the health page and
   `rehearsal/`'s report items by hand (gaps, webhooks), and delete the
   GitHub secrets the old CI deploy used (`DEPLOY_SSH_KEY`,
   `DEPLOY_KNOWN_HOSTS`, `DEPLOY_HOST`, `DEPLOY_USER`) and that key's line
   in the server's `authorized_keys`.

## The shadow machine (§10.5, §15.2)

A second machine, independent of the main VPS (another provider or
network, its own power), that keeps collecting when the main VPS can't.
It needs no open port: Tailscale links it to the main VPS, and Cloudflare
Tunnel brings it webhooks. It runs:

- **the shadow collector** (`kamal/shadow.yml`): polls and chat for the
  same channels, all the time, into its own database
  (`compose.shadow.yml`). The main VPS fills its own gaps from it every 5
  minutes (`Workers.Backfill`), for the last `BACKFILL_DAYS` (7);
- **the backup receiver** (`kamal/backup-receiver.yml`): the ingress
  Worker (`ingress/worker`) sends it each webhook the main VPS can't take;
  it spools it and publishes to the main RabbitMQ over Tailscale once
  that answers;
- **the follower** (`shadow-follow.sh`, a systemd timer): deploys what
  the main VPS runs, once it has been live and healthy there for
  `KT_SHADOW_SOAK` (6h).

Each is one role, no standby: a deploy stops it, starts the new build,
waits until it's healthy, and puts the previous build back if it never
is. A few seconds without the shadow only matter if the main VPS is down
at that moment.

### Setting it up (once)

1. **The machine**: Docker with its buildx plugin
   (`docker-buildx-plugin`: the attestation gate resolves each image to a
   digest with it, and refuses the deploy without it), git, `psql`
   (postgresql-client) and Kamal (or `KIT_RUNNER=docker`), a deploy user
   in the `docker` group, joined to the tailnet. In its firmware, power on after a power cut.
2. **Tailscale ACLs**, only these (tag the two machines):
   the shadow machine to the main VPS's 5432 (the database, as
   `shadow_reader`) and 5672 (RabbitMQ, as the publish-only `receiver`);
   the main VPS to the shadow machine's 5433 (its database, as
   `backfill_reader`). SSH to the shadow machine from wherever you deploy.
3. **The main VPS**: `PRIVATE_IP=<its Tailscale address>` in its
   `deploy/.env`, then `docker compose -f compose.single.yml up -d db
   rabbitmq` (a restart of a few seconds: the collectors' journals and the
   receivers' spools hold what arrives meanwhile). Docker's published ports
   bypass `ufw`: the ACLs are what limit them. Then the read-only users
   (`shadow/readers.sql`, `shadow_reader` part) on the main database.
4. **A second Kick app** on kick.com, for the shadow (its own token and
   rate limits; it subscribes to nothing).
5. **Secrets**: an age key on the shadow machine; its public key in
   `../.sops.yaml`'s first rule (then `sops updatekeys` those files).
   From the examples in `secrets/`: `shadow.sops.env` (the shadow's Kick
   app, `MAIN_DATABASE_URL` with the main VPS's Tailscale address),
   `shadow-db.sops.env`, `backup-receiver.sops.env` (`AMQP_URL` with the
   main VPS's Tailscale address). The main VPS can't read these, and the
   shadow machine can't read the main VPS's.
6. **The checkout the deploys sync** (like the main VPS's): clone the repo
   to `KT_SHADOW_DEPLOY_DIR` (e.g. `/srv/kick_tracker`) and in its
   `deploy/.env`: `PRIVATE_IP=<its Tailscale address>` and
   `SECRETS="shadow shadow-db backup-receiver"` (`secrets/decrypt.sh`
   then decrypts only those). `docker network create kamal`, then
   `deploy/secrets/decrypt.sh` and `docker compose -f compose.shadow.yml
   up -d`; on its database, the `backfill_reader` part of
   `shadow/readers.sql`.
7. **Wherever you deploy it from**, in `.kamal/kit.local.env`:
   `KT_SHADOW_HOST` (the Tailscale address), `KT_SHADOW_SSH_USER`,
   `KT_SHADOW_DEPLOY_DIR`. The first deploy: `deploy/shadow.sh`.
8. **On the main VPS's side**, `SHADOW_DATABASE_URL` in `collector.env`
   (`backfill_reader`, the shadow machine's Tailscale address, port
   5433), then `kit group deploy collectors`: the backfill starts, and the
   health page shows the shadow.
9. **Webhooks**: on the shadow machine's tunnel, a public hostname to
   `http://localhost:4060`; then the Worker on the webhook hostname
   (`ingress/worker/README.md`). The main VPS keeps its hostname and
   Caddy as they are: the Worker reaches it through the same hostname.
10. **The follower**, on the shadow machine: a second checkout of `main`
    that only deploys (`~/kicktracker-deployer`), with the step 7 settings
    in its `.kamal/kit.local.env`, plus `KT_FOLLOW_SITE_HEALTH` (the
    site's `/healthz`) and `KT_FOLLOW_INGRESS_HEALTH` (the webhook
    hostname's `/health`; one the backup answered doesn't count), the
    kit's notification settings, a GitHub token that can
    read the repo's checks and attestations (`gh auth login`), and
    `KT_REGISTRY_PASSWORD` (a read-only GHCR token). Then the timer:
    `shadow/kicktracker-follow.service` says how.
11. **Check it before relying on it**: stop the main receivers
    (`kit kamal app stop -c deploy/kamal/receiver.yml`), send a test
    webhook through the Worker (the answer says `x-ingress-target:
    backup`), start them again and see it reach RabbitMQ; stop the shadow
    collector and see the "shadow collector" alert after 15 minutes; see
    the backfill fill a gap (`coverage` rows with `collector = 'shadow'`).

### Day to day

    deploy/shadow.sh --status             # what each runs
    deploy/shadow.sh                      # this checkout's commit, now
    deploy/shadow.sh --version <sha>      # another build (a rollback)
    deploy/shadow.sh --only shadow        # one of the two
    deploy/shadow-follow.sh --status      # on the shadow machine: the soak clocks
    deploy/shadow-follow.sh --now         # the main VPS's builds, now
    deploy/shadow-follow.sh --pause / --resume

`shadow.sh` is the kit's usual deploy (the same gates: `main`, clean and
pushed, CI green, attestations; then the shadow machine's checkout and
secrets, and its own database's migrations) without the main VPS's smoke
tests. A group already on the build is left alone. Releases of the main
VPS (`release.sh`) never touch the shadow machine.

The follower checks every 10 minutes what the main VPS runs (the leading
collector's build; the receivers' `/health`) and whether it's healthy (a
leader, no open alert, the site and the receivers answering). A build
healthy for `KT_SHADOW_SOAK` is deployed to the group that runs it; any
unhealthy check starts the clock again. It follows the main VPS moving,
not what the shadow runs: a build you deployed by hand stays until the
main VPS changes. A failed deploy is retried after `KT_FOLLOW_RETRY` (1h);
the kit notifies each deploy and failure. Its log: `journalctl --user -u
kicktracker-follow`.

**The shadow runs up to `KT_SHADOW_SOAK` behind the main VPS**, so the
main VPS's backfill reads the shadow's database written by an older
build: a column it reads there must already exist one soak earlier
(AGENTS.md §8).

The shadow's data is kept `SHADOW_KEEP_DAYS` (30) and isn't backed up: it
only matters until the main side has filled its gaps. The shadow
notifies when it can't reach the main VPS (its own `NTFY_URL`); set its
own `HEARTBEAT_URL`, so the shadow dying is noticed too.

## Backups (§18.1)

- WAL is archived continuously by the database (`db/archive.conf`): at most
  a minute is lost. WAL-G writes to the `backups` volume (`/backups` in the
  database container), encrypted (`WALG_LIBSODIUM_KEY`) and compressed.
- `backup/base-backup.sh`, daily: a full base backup and pruning (keeps 7).
- `backup/offsite-sync.sh`, every 5 minutes: mirrors the `backups` volume
  to Filen with rclone, so the VPS going takes at most 5 minutes of history
  with it. Its settings are `secrets/offsite.env` (example in
  `offsite.env.example`): the Filen account, its password and API key
  rclone-obscured, and the folder (never the drive's root, which is
  refused). A store without WAL (a new or
  emptied volume) is never mirrored, so it can't empty Filen; what pruning
  removes goes to Filen's trash. It alerts after 3 failed runs in a row,
  then hourly while it lasts, and pings `OFFSITE_HEARTBEAT_URL` after each
  sync.
- `backup/restore-test.sh`, weekly: downloads the copy on Filen (or, with
  `RESTORE_FROM=local` or no `offsite.env`, uses the volume), restores the
  latest backup into a
  scratch container, replays the WAL, checks row counts against the live
  database (the stack's `db`, through `docker compose exec`, when it runs
  on the same host; or `LIVE_DATABASE_URL`) and that recent streams'
  figures agree with their samples.
- Both run from the deploy user's crontab (the cron lines are at the top
  of each script) and need nothing from cron's environment: they read
  `secrets/db.env` (WAL-G's storage, `POSTGRES_USER`/`POSTGRES_DB`,
  `BACKUP_HEARTBEAT_URL`, `RESTORE_HEARTBEAT_URL`) and the alert settings
  of `secrets/collector.env` (or `app.env`). Any failure, expected or not,
  is sent to `ALERT_WEBHOOK_URL`, Telegram and/or ntfy; each success pings
  its heartbeat URL, so a job that stops running is noticed too.
  `ops/check-host.sh` reads its settings the same way; besides disk and
  certificates it alerts when more than 30 WAL segments wait to be
  archived (a failing `archive_command` doesn't stop Postgres: it keeps
  every segment, and fills the disk).
- Keep `WALG_LIBSODIUM_KEY` somewhere off the VPS too (it is in
  `db.sops.env`, so the age key and the repo are enough): without it no
  copy can be read.
- Also keep: `deploy/` (in git), the RabbitMQ definitions (regenerated from
  secrets), and the age private keys (offline). Receiver spools are
  short-lived and not backed up.

Each collector's journal (`journal-a`, `journal-b`) holds writes only
until the database has them, and isn't backed up; don't delete a volume
whose collector reports writes waiting (health page).

To restore for real, stop both collectors and web (`kamal app stop -c
deploy/kamal/app.yml`, through `kit` or with `.kamal/kit.local.env`
exported), then follow the same steps
as the restore test into the production volume (with `recovery_target_time`
set if you need a moment before a mistake).

## Monitoring (§18.2)

- Alerts are checked every minute by the collecting node **and** by web
  (so a dead collector is noticed), and sent through `ALERT_WEBHOOK_URL`,
  Telegram or ntfy (`NTFY_URL`, with the priority: high when a problem
  starts, low when it is resolved); the admin health page shows the open
  alerts and each collector: collecting or standing by, writes waiting,
  recent handoffs.
- Each collector's container healthcheck asks its own status port
  (`docker ps` shows it; `.kamal/kit/bin/kit group status` shows which
  collects).
- External checks, from a service off the VPS (e.g. healthchecks.io or
  UptimeRobot):
  - `https://$SITE_HOST/healthz` and `https://$INGRESS_HOST/health`;
  - `HEARTBEAT_URL` (the collecting node pings it every minute: set it),
    `BACKUP_HEARTBEAT_URL` (daily), `OFFSITE_HEARTBEAT_URL` (every 5
    minutes) and `RESTORE_HEARTBEAT_URL` (weekly):
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
