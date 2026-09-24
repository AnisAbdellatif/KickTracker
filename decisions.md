# Decisions

Decision log (see AGENTS.md §3), tracked in git and public with the repo.

## Scope

**Current:** Track a chosen set of Kick channels (a handful at first, able to grow to hundreds or low thousands); Kick only, no other platforms. (updated 2026-09-24 04:04)

Tracking every channel on Kick is not the goal. Multi-platform (e.g. YouTube, as Streams Charts does) was considered and left out for now: adding `(platform, platform_id)` would cost little, but Kick-only keeps the model simpler, and our own channel ids leave the door open.

## Authorization

**Current:** One Kick app with an app access token (client credentials) for all public reads and webhook subscriptions; no channel owner authorization. (updated 2026-09-24 04:04)

Kick's docs: app tokens can subscribe to any channel's events by passing `broadcaster_user_id`. User tokens (owner logs in) are only needed for private data or acting on someone's behalf; kept for a possible later "streamer accounts" feature.

## Data Sources

**Current:** Official public API for polling (viewers, channel state), official webhooks for events, Kick's private v2 API only for the follower total, Pusher websocket for chat and raids/hosts. (updated 2026-09-24 04:04)

- The public API has no follower count; `channel.followed` gives gross follows only (no totals, no unfollows). v2 `followers_count` answered a plain `curl` from home (200, with the expected count for a test channel); must still be tested from the VPS. Read only that field, never store the rest (it has a signed `playback_url`).
- Chat stays on Pusher, not the `chat.message.sent` webhook: one HTTP request per message is heavy, and unverified apps are capped at 1 000 channels. The webhook is the fallback if Pusher stops.
- Webhooks have no raid/host event, so those stay on Pusher.
- v2 and Pusher are unofficial; both are isolated and optional so the rest keeps working without them.

## Tracking Cadence

**Current:** Viewers every 60s by polling `/livestreams` for **every** tracked channel (not only the live ones); stream start/end and title/category from webhooks, with the 60s poll as the safety net; subscriber counts and slug renames from `/channels` every 5 minutes; followers every 15 min live, daily offline, plus at stream start and end; chat per minute. (updated 2026-09-24 12:40)

Owner's spec for the cadences. Kick refreshes `viewer_count` about every 60s, so the owner moved viewer polling from 15s to 60s. Hours watched caps Δt at 75s: a cap equal to the interval would undercount every slightly late poll, while 75s fills at most 15s of a missed poll. The plan polled `/livestreams` only for channels believed live and relied on the 5-minute `/channels` poll to notice a missed start; polling every tracked channel costs one request per 50 channels a minute and notices a missed start within a minute, with one code path for stream state instead of two. `/channels` keeps the jobs only it can do (subscriber totals, renames).

## Stream Identity

**Current:** A stream is keyed on `(channel_id, started_at)` using Kick's `started_at`. The pure `Metrics.Sessionizer` turns status events and poll readings into streams: Kick's end event always wins and a stream it closed never reopens; without it a stream ends at its latest live evidence, which only ever moves later; a newer `started_at` closes the previous stream; a poll must miss the channel for 90s after the last evidence before it counts as offline; a poll-closed stream seen live again after the offline poll reopens (Kick keeps `started_at` through short disconnects); evidence about an unknown older stream records it. The same rules are enforced in the upsert SQL for streams no longer in memory. (updated 2026-09-24 12:40)

Kick sends no livestream id in `livestream.status.updated` or `GET /livestreams`. Both report `started_at`, so it is the only key both paths agree on (confirmed on recordings). The rules were chosen so arrival order doesn't change the result; property tests shuffle and repeat a true history's observations (start and end events, readings every minute, the API's ~20s lag after an end, offline polls) and check the outcome. They found one order dependence: offline polls arriving before any evidence of the stream they follow were ignored. Fixed by keeping the latest offline poll even when no stream is open. The 90s grace is there because the API lags Kick's state (a start event can precede the stream appearing in the API). Mutations of the rules were checked to fail the properties.

## Backend Language

**Current:** Elixir / Phoenix. (updated 2026-09-24 04:04)

Compared with Go and Bun. At our scale all three handle the load; the deciding factor is staying correct for months: supervised process per channel, crash isolation, fair scheduling, cheap websockets, LiveView + PubSub for live pages, Oban, Broadway, built-in clustering. Go needs hand-written supervision and a separate frontend; Bun (briefly chosen before) shares one event loop, so one bad channel can stall or crash all, and Next.js needs a relay for live data. Cost: learning OTP.

## Architecture

**Current:** Three parts: ingress (webhook receivers) → RabbitMQ → app. The app runs as two roles, `collector` and `web`, from one image, deployed separately. (updated 2026-09-24 04:04)

Owner requirement: updating logic must never stop webhook intake. The app only knows the queue, so who receives webhooks and how redundantly is a deployment choice (self-hosted receivers now, Cloudflare/managed later). A separate BEAM process tree alone adds nothing (Phoenix already isolates requests); hot code upgrades were rejected as routine deploys (complex, poor fit with containers) but kept as an occasional tool.


## Collector Availability

**Current:** Two collectors run; one leads and collects, the other stands by (`Collector.Leader`, rules in the pure `Collector.Lease`). The lease is a Postgres advisory lock on the Leader's own connection plus a `collector_lease` row whose epoch rises at every change of holder; `collector_terms` records each term and why it ended. A standby (checking every second, on the database's clock) takes over at once when the leader released the lease on a clean stop, or when the lock is free and the database did not restart since the leader's last heartbeat (its session ended: a crash); it ends the session of a leader that holds the lock but has been silent for 6s (frozen or cut off) and then takes over; after a database restart it gives the leader 10s to take its lock back. A node restarting takes its own lease back at once; the leader heartbeats every second. The leader keeps collecting while the database is unreachable and stops at once when superseded or when another node holds the lock. Every collected write goes to a local SQLite journal (`Collector.Journal`) as a data operation naming streams by `(channel, started_at)`, and a Writer applies it to Postgres exactly once (a high-water mark per journal in the same transaction), waits out the database with backoff, sets aside writes that can never apply, and drops writes an older holder made after a newer one started (fencing by epoch). Polled data comes from `Collector.Source` modules run by one `SourceRunner` (cadence, concurrency, deadlines, isolation, coverage, journaling); chat stays one socket per channel, journaling through the same path. A watchdog restarts collection if the viewers source stops completing cycles; the collection tree is restarted with backoff and can't take the node down. Each collector has a loopback status endpoint (container healthcheck, deploy script) and a `collector_nodes` heartbeat row read by web. (updated 2026-09-24 19:30)

The owner's requirement: the web role can restart freely, collection must not stop. The audit that led here found the collector crash-looping the whole node when the database was away (the Manager and Poller raised on every restart, beyond the root supervisor's default 3 restarts in 5s), nothing buffered, deploys a stop-then-start gap, a poison event able to stop a channel for good, a chat upgrade able to hang forever, polling batches run one after another with uncapped `retry-after`, and nothing outside the collector noticing it dead.

Alternatives: **one collector with faster restarts** fixes crashes but not deploys or host-level restarts, and every restart is still a gap. **Two collectors active at once** (both polling, both chatting) would need every write idempotent across nodes; chat counts are additive by nature (late messages add to a written minute), so double collection would double them. **Leader election through Oban's peer or Erlang distribution (`:global`)** would tie the lease to clustering, which the roles don't otherwise need, and `:global` splits on a partition; a lock in the one database every node already shares has no split-brain, and the epoch fences the one race it has (a database restart freeing the lock while the old holder still runs). **Buffering only on failure** (write directly, spool when the database errors) would leave two write paths, one of them rarely exercised; journaling everything means the tested path is the path. **Memory-only buffering** loses what was waiting if the collector restarts during a database outage; the owner chose the disk journal. **Chat as a polled source** doesn't fit (it's a socket per channel), so the behaviour covers polled sources and chat shares the journal, coverage and status plumbing.

Takeover timing: the first version waited 15s of silence plus 5s of a free lock before taking over from a crashed leader, to let a leader whose connection blipped get its lease back; a free lock with the database not restarted since the leader's last heartbeat (`pg_postmaster_start_time()`) already means the leader's session ended, so that wait now applies only after a database restart, and a crash is taken over within a second. The same review found a hole: a leader frozen or cut off with a half-open connection keeps its session, and the lock, until TCP notices (hours by default); the standby now ends that session (`pg_terminate_backend`, allowed between sessions of the same database user) after 6s of silence. A false positive (a leader briefly too slow to heartbeat) costs a handoff, fenced, not data. Every query on `pg_locks` is scoped to the current database: advisory locks are per database but the view is server-wide, and an unscoped check let a shadow on the same server end the primary leader's session. A leader process starting stops any collection tree left in its slot by an earlier incarnation (one that crashed without stopping it), and its default hooks are plain calls rather than stored functions, which a code reload would invalidate. For the machine itself going, see Shadow Collector. A channel process that starts during a database outage without a snapshot starts afresh, so a stream that ended meanwhile may be closed later by its end event rather than by polling.

## Shadow Collector

**Current:** An independent collector on a second machine with its own database (`COLLECTOR_MODE=shadow`, `compose.shadow.yml`), collecting the same channels all the time (polls, followers, chat; no webhooks, no subscriptions, no site). It copies the channel list and removal requests from the primary's database every minute over the private network with a read-only user, keeps its last list when it can't, and notifies after 5 minutes of not reaching the primary. The primary side's `Workers.Backfill` reads the shadow's database every 5 minutes and, per channel and source over the last 7 days, copies the shadow's rows for the ranges the shadow covered and it didn't, as `Collector.Ops` (ours always win; chat only for whole minutes we have nothing for), recording each filled range in `coverage` with `collector = 'shadow'`. Its own Kick app, its own heartbeat; alerted on when unseen for 15 minutes. Keeps 30 days, not backed up. (updated 2026-09-24 19:30)

The owner wants collection to survive the main VPS going, and asked for a collector that could run elsewhere. A standby on another machine can't: the lease, the journal's destination and everything it writes are in the main VPS's database, which goes with the machine; making it work would mean a replicated database with failover (stage 3), a much larger change. Collecting all the time into a database of its own needs none of that, has no takeover at all (it was already collecting), and covers every cause of a gap on the primary side, not just a machine failure: a bug, a bad deploy, both collectors down. Its data joins ours the way an import does (natural keys, existing rows win), so the machinery was already there. Alternatives considered: the shadow writing into the primary's database when it's back (it would need to know when the primary missed something; the primary knows its own coverage, so it pulls); streaming the shadow's journal to the primary (couples the two formats, and the shadow's data is useful on its own); webhooks on the shadow too (the backup receiver already spools them, and two consumers of Kick's subscriptions would fight). The cost is double polling and chat connections, which Kick sees; a second Kick app keeps the shadow's token and limits independent. Chat minutes the primary had partly (the minute an outage began) keep the primary's partial count rather than risk counting twice.
## Queue

**Current:** RabbitMQ: topic exchange `kick.events`, quorum queue `kick_tracker.events`, publisher confirms, dead-lettering, consumed with Broadway (`broadway_rabbitmq`). (updated 2026-09-24 04:04)

Owner's choice over NATS JetStream. RabbitMQ has the official Broadway producer and runs on the BEAM; managed option (CloudAMQP) needs no app change. NATS was lighter with built-in dedup, but its Elixir support is community-only. No built-in dedup in RabbitMQ is fine: the app dedupes on `message_id`.

## Ingress and Redundancy

**Current:** Minimal Elixir receiver (verify, envelope, publish with confirms or spool to local SQLite, answer 200), never touching the database. Stage 1: two receivers on one VPS behind Caddy; stage 2: backup receiver on a second VPS routed by Cloudflare Load Balancing; stage 3: redundant queue if ever needed. (updated 2026-09-24 04:04)

Missed webhooks are lost forever. Kick unsubscribes after failing "for over a day"; its retry policy is otherwise undocumented (to test). A backup on another machine can't depend on the main database, hence the local spool. DNS round-robin rejected (client-dependent failover); floating IP rejected as primary option (same provider only).

## Event Envelope

**Current:** Receivers wrap each delivery in a JSON envelope (`contracts/envelope.md`, version 1) carrying the raw body and signature; the app re-verifies. Fields named `event_type` / `event_version` for Kick's values and `envelope_version` for ours; `message_id`, `sent_at` and `body` copied byte for byte; non-UTF-8 bodies travel as `body_base64`. Contract: at-least-once, no ordering, ack after commit, short queue retention with `webhook_events` as the permanent record. (updated 2026-09-24 04:20)

Keeps the app independent of the ingress and trusting neither the queue nor the receivers. The first sketch had a single `version` field, which would have mixed up Kick's payload version with our envelope's version; they change for different reasons, so they are separate. `sent_at` is kept verbatim (not parsed) because it is part of the signed text. Changes are backward-compatible only; consumers ignore unknown fields.

## Database

**Current:** PostgreSQL + TimescaleDB, one database, self-hosted. (updated 2026-09-24 04:04)

Compared with plain Postgres (portable, no compression, own rollups) and Postgres + ClickHouse (best analytics, two databases, no transactions/unique keys on the ClickHouse side). With the chat structure below every heavy query is small at our scale. Cost: compression and continuous aggregates aren't offered by generic managed Postgres, so self-host or Timescale's cloud. Growth path: ClickHouse alongside Postgres (Plausible's model).

## Data Model

**Current:** Store append-only raw facts, derive everything else; own channel ids with `kick_user_id` unique; slugs with history; UTC storage with the channel's timezone applied at read time; title/category as a change log with derived segments, and category also on each viewer sample. (updated 2026-09-24 04:04)

Lets any formula change later and history be recomputed. Slugs change on rename. Weekday/daily figures in UTC would be wrong for the channel's audience.

## Chat Storage

**Current:** Three levels: `chat_minutes` (counts per channel-minute, forever), `chat_minute_users` (per chatter per minute, 90 days by retention policy), `chat_stream_users` (per chatter per stream, forever). No message text ever. The `ChannelServer` gathers chat per minute of Kick's own timestamp (pure `Metrics.ChatMinutes`, deduplicated by message id) and writes a minute 30s after it ends, every 15s, and everything on shutdown. A message arriving after its minute was written is added to it: `chat_minute_users` rows add up, and `chat_minutes` is recounted from them. A minute belongs to the stream live during it; offline chat is counted with no stream. (updated 2026-09-24 13:40)

Unique counts don't add up, so arbitrary windows need per-user rows. Windows inside a stream read only that stream's rows; long-range questions use the per-stream table, 20–50× smaller. 90 days (owner's choice) caps the largest table and limits personal data. HyperLogLog / roaring bitmaps kept in reserve. Recounting `chat_minutes` from the per-user rows, rather than adding counts, keeps "distinct chatters in the minute" right when a late message's sender was already counted.

## Chat Socket

**Current:** One `ChatSocket` per channel (Mint.WebSocket in a GenServer, under the channel's `rest_for_one` supervisor, after its `ChannelServer`). It subscribes to `chatrooms.<chatroom id>.v2` and, once known, `channel.<kick channel id>` (learnt from `/livestreams`' `channel_id`); answers pings, pings after Pusher's activity timeout and reconnects if no pong comes in 30s; reconnects with backoff 1s→30s; decodes frames that arrive in the same read as the 101 upgrade. Chat coverage is extended every minute while subscribed and closed on disconnect. It waits until the chatroom id is known. (updated 2026-09-24 13:40)

Our own GenServer over Mint rather than WebSockex: the process owns the connection and the reconnect and coverage logic, as planned in §9.

## Raids and Hosts

**Current:** Not parsed yet. Their Pusher event names were never recorded, so nothing guesses them: every chat-feed event the parser doesn't know is reported to the `ChannelServer` by name only (its data is dropped) and logged once per name per channel. `channel_events` exists (with a `dedup_key` unique per channel, and `other_channel` as text) for when a recording shows the names and fields. (updated 2026-09-24 13:40)

AGENTS.md forbids writing payload shapes from memory or documentation. Logging unknown names means the first real raid seen in production (or a recording) says what to parse, without having stored anything it carried.

## Frontend

**Current:** Phoenix LiveView for public site and admin; history served as cacheable JSON (`/data/v1`), only live data over LiveView; server-side resolution by range (≤ ~2 000 points, avg + max per bucket); English first, Gettext and RTL-ready layout. Visual style: daisyUI with our own light and dark themes (warm neutral canvas, white cards, one blue accent, flat with 1px borders), a sticky header, segmented controls for period and metric, underline tabs, and channel initials on a palette tint instead of avatar images. (updated 2026-09-24 15:00)

Keeps per-visitor memory tiny (no chart data in assigns) and lets Caddy/Cloudflare cache history. Max per bucket prevents downsampling from hiding peaks. The themes replace daisyUI's defaults, whose orange/indigo clashed with the chart palette; status colours (success/warning/error) are kept apart from the categorical hues. Initials rather than Kick's avatar images: nothing to fetch, store or hotlink, and they stay stable when a channel changes its picture.

## Charts

**Current:** Apache ECharts 6, installed from npm into `app/assets` (package.json), imported modularly (only line, bar, pie and heatmap and the components used) and loaded by dynamic `import()` from the one `Chart` hook, so esbuild splits it into its own chunk (esbuild now runs with `--splitting --format=esm`, and `app.js` is a module script). Chart kinds: `timeseries`, `stream`, `bars`, `share`, `heatmap`, `sparkline`; the server sends data, a kind and labels/columns, never options. Table view and CSV export in the hook, from the same JSON. Colours are CSS custom properties (`--viz-1..8`, `--viz-seq`, chrome tokens) read by `charts/theme.js`: an eight-hue categorical palette in fixed order with separate light and dark steps, one blue ramp for heatmaps, 2px lines with a ~10% area wash, hairline grids, bars capped at 24px with rounded data ends, a legend only for two or more series. Time charts open zoomed to the stretch that has data (the hook computes it from the series, 2% room either side) on an axis spanning the whole period; the reader's zoom survives re-renders (live points, theme), and double-click or a "show all" button fits the data again. (updated 2026-09-24 20:45)

Needs shaded bands (category segments, no-data), event markers (raids, gifts), linked zoom across panels, heatmaps and dense series in one library. Chart.js (earlier pick) needs plugins for most of that; uPlot is faster but too narrow. The full ECharts bundle was 2.8 MB unminified; modular imports bring the chart chunk to about 670 KB minified, loaded only on pages with charts. `stream` was added to the planned kinds: the stream page's three stacked panels sharing one zoom are one ECharts instance, which a generic `timeseries` couldn't express without sending options. The palette replaced Okabe–Ito because Okabe–Ito's yellow and sky blue fall below contrast on a light surface and it has no matched dark steps; the new one was run through a colour-vision-deficiency check (adjacent pairs, both themes) and passes, with the light-mode contrast warning covered by legends and the table view. Tokens live in CSS so the charts, avatars and meters share them and a theme switch re-renders charts from the same source. Fitting by default instead of cutting the axis to the data: the empty part of a period is real information (we weren't tracking yet, or weren't collecting), so it stays one zoom-out away rather than hidden. The zoom is applied as the dataZoom window by the hook, generically for every time kind, so kinds stay unaware of it; before, each re-render replaced the chart's state and reset any zoom, every minute on a live stream page.

## Public Site Data

**Current:** Charts read `/data/v1` JSON (columns: `t` in unix seconds plus one array per value; `gaps` from coverage), with an ETag and `Cache-Control` of a day for ranges ended more than two days ago and 30s otherwise. The resolution is picked by the pure `Series.Resolution` from the span (raw ≤ 12h, 5 min ≤ 7d, hourly ≤ 90d, daily beyond, in the channel's timezone); `res` may only ask for fewer points. Hourly and daily series read `hourly_stats`. Chat counts are 0 only where chat coverage says we were listening; empty viewer buckets are null. Expensive aggregates go through `KickTracker.Cache` (ETS, TTL 60s for periods reaching into the last two days, an hour otherwise). New vs returning chatters per stream is computed by the rollup into `stream_stats.new_chatters`. (updated 2026-09-24 07:00)

Cachex was planned for the query cache; a 60-line ETS table with a TTL and a sweep covers what we need without a new dependency. Computing new chatters at read time took 2.7 s for a big channel's month (it had to find every chatter's first stream) and timed out a test; per stream in the rollup it is about 0.2 s once. Daily buckets exceed 2 000 points after about five and a half years; weekly buckets are left for then. Pages reproduce from their URL: `period=24h|7d|30d|90d|1y|all` or `from`/`to`.

## Stream Corrections

**Current:** `stream_overrides` (exclude, merge; revocable, never deleted) layered over the raw streams. `excluded_streams` is a view of active exclusions that every public figure filters on (KPIs, records, categories, notable moments); excluded streams stay listed, marked. `merged_streams` is a view of active merges: the later stream disappears from lists and counts, the earlier one runs to the later one's end, and its `stream_stats` are computed over both (a merged stream's page redirects to it). Split is allowed by the table but not built. (updated 2026-09-24 07:20)

Raw facts are append-only (AGENTS.md §7), so a correction can only be a row on top. A view keeps the filter in one place for SQL. Split needs an address for each half (a stream is its row and id), which merging doesn't; it waits for a real case. Hourly rollups leave out an excluded stream's viewer samples, so channel totals and leaderboards agree with the stream list; follows, chat and support during it still count toward the channel (they happened), and changing an override rebuilds the rollups of the stream's hours.

## Admin

**Current:** Under `/admin` in the `web` role, invite-only, password + TOTP on every login; optionally only reachable over the private network. Accounts are written by hand on phx.gen.auth's model (random session tokens in the database, looked up per request and per LiveView mount; logout deletes the token and disconnects live pages), not generated: PBKDF2-HMAC-SHA512 from OTP's `:crypto` (210 000 iterations, count kept in the hash) instead of bcrypt, and our own RFC 6238 TOTP (`Admins.TOTP`, tested against the RFC's vectors) that refuses a code for a step already used. Invitations are one-use links valid 7 days, stored hashed, shown once to the inviting admin to send by hand; the first comes from `mix kick_tracker.admin.invite` / `KickTracker.Release.invite/1`. Every admin action goes to `admin_audit_log`. Corrections are layered on raw data, never edits. (updated 2026-09-24 06:20)

phx.gen.auth in Phoenix 1.8 generates magic-link login by email and public registration, both of which would have to be torn out (no mail is configured, no public sign-up), and it adds `bcrypt_elixir`, a native dependency; TOTP would have needed `nimble_totp`. The pieces kept from it are the ones that matter for security (server-side session tokens, renewing the session on login, disconnecting sockets on logout). The enrolment shows the secret and the `otpauth://` URI as text rather than a QR code, to avoid a QR library; any authenticator app accepts a typed key. Login failures give one message for every factor, and an unknown email costs as much time as a wrong password.

## Admin Actions on a Web Node

**Current:** A web node that doesn't collect runs its own `Kick.Token`, so the admin can look a slug up before adding it and the health page can list Kick's webhook subscriptions. Admin writes (a channel added, paused, its timezone) are row changes plus `"channels:changed"`; the collector's `Tracking.Manager` also reconciles from the database every minute (was 5), so a lost broadcast only delays a change. Timezones are validated against PostgreSQL's `pg_timezone_names`, which is also what applies them at read time; the add form suggests one from the stream's language, always editable. (updated 2026-09-24 06:20)

The alternative for lookups was to insert a pending row and let the collector resolve it, which makes the admin wait for a job to see whether a slug exists. The web node holding the client secret is acceptable: it already holds the database credentials. PostgreSQL rather than a `tzdata` dependency, since the database is where timezones are applied anyway.

## Health Page

**Current:** The health page reads only the database (the collectors from their `collector_nodes` heartbeat rows and `collector_terms`, plus RabbitMQ's management API, when `RABBITMQ_MANAGEMENT_URL` is set, through a `monitor` user with the `monitoring` tag and empty permissions), so it works on a web node. A source's state comes from its latest `coverage` outcome: ok, failing, stale (older than a little over two cadences) or never. Coverage % is the pure `Metrics.Coverage.fraction/4`: each ok period vouches for its first to last outcome plus one cadence. `webhook_events` gained a nullable `broadcaster_user_id`, filled from the body when stored, for "last event per channel". (updated 2026-09-24 06:20)

The collector's processes know more (socket state), but asking them from a web node needs clustering, and the database already records every outcome. Without the column, the last event per channel would mean decoding every recent body, and `convert_from` fails on a non-UTF-8 body. Rows stored before the column stay null rather than being backfilled (raw rows aren't updated). The monitoring user needs a permission entry in the vhost (empty patterns) to see its queues through the API.

## Admin Operations

**Current:** Admin actions that change collected data run on the collector as Oban jobs the web node queues: `Workers.Reprocess` (recompute rollups for a range and given streams; replay stored `webhook_events` through the current handlers, skipping redacted ones) and `Workers.Privacy`. Dead letters are handled from the web node over AMQP as a dedicated `ops` user (read the dead-letter queue, write the exchange): listing takes messages unacknowledged and puts them all back, and waits (up to 2s) until the quorum queue shows them ready again before returning; a replay is acknowledged only after RabbitMQ confirms the republish; a discard needs a reason, kept in the audit log with the message's id and type. Groups are admin tables with a public flag; settings are feature flags and the revenue assumptions, with defaults in code, so an empty table works. (updated 2026-09-24 21:00)

Putting messages back in a quorum queue lands asynchronously: without the wait, a count, a listing or a replay right after a listing could miss them (a replay answered "not found"), which also made the dead-letter test fail about one run in three. The web role writes only admin tables (AGENTS.md §8), so anything touching raw or derived tables is a job, which also survives a web redeploy mid-action. Dead letters live in RabbitMQ, not the database, so the web node needs its own least-privilege broker user rather than borrowing the consumer's. Polling cadences were planned as settings; they stay in code because the 75s hours-watched cap and the coverage gaps are derived from them.

## Privacy Deletion

**Current:** A deletion request (admin, confirmed by retyping the Kick user id) removes the person's username and per-person chat rows, sets their id to null in `follows` (now nullable) and `support_events` so the counts stay, scrubs them from support payloads, and redacts `webhook_events` bodies that name them, marking those rows `redacted_at` (they no longer verify against Kick's signature and are never replayed). Aggregates already computed stay. (updated 2026-09-24 07:20)

This is the one exception to append-only raw facts, because the law requires it; it is audited. Nulling ids instead of deleting rows keeps follows, subs and gifts counted, which identify no one once the id is gone. The body search is by the id's digits, so it may look at bodies that only contain them inside a longer number; the JSON-aware scrub changes only real matches.

## Alerts and Errors

**Current:** Alerts are evaluated every minute by the pure `Alerts.Rules` over a snapshot (per channel: live, last poll, chat, 24h coverage; system: last webhook, oldest unprocessed event, dead letters, queue depth, clock drift; the collectors from their `collector_nodes` heartbeat rows: none collecting, a standby gone, writes waiting in a journal for over 5 minutes, writes set aside, the shadow collector unseen for 15 minutes). They run on the leading collector (`Workers.Alerts`) **and** on web nodes (`Alerts.Ticker`); a transaction-scoped advisory lock lets one check at a time. Each problem has a stable key and a row in `alerts` while it lasts: notified when it starts, reminded every 6 hours, and notified when resolved. Targets: a Discord/Slack webhook (`ALERT_WEBHOOK_URL`) and/or Telegram; `HEARTBEAT_URL` is pinged each minute by the collecting node as a dead man's switch. Errors go to ErrorTracker (in our database, dashboard at `/admin/errors`), including crashes of any process through a `:logger` handler, and a new kind of error is notified. `/healthz` is for external uptime checks. (updated 2026-09-24 18:00)

A job on the collector can't report the collector being down: checking from web too covers a dead or stuck collector while the site runs, and the heartbeat to an outside service covers both. Collector rules say nothing where no collector ever reported, so a site-only deployment stays quiet. Host-level checks (disk, certificates, backups) are scripts in `deploy/`, not the app. ErrorTracker over Sentry: self-hosted, in the same database, and its only dependencies were already ours; on its own it sees requests, LiveViews and Oban jobs, so the logger handler adds GenServer, proc_lib and Task crashes. Thresholds sit above normal jitter (a live channel without a reading for 5 minutes has missed five polls).

## Dependencies Added After Phase 2

**Current:** `error_tracker`, `plug_attack`, `exqlite` (the collector's journal, the same version the receiver's spool uses), and in dev/test `credo`, `dialyxir`, `sobelow`, `mix_audit` (with their dependencies `bunt`, `erlex`, `yaml_elixir`, `yamerl`). (updated 2026-09-24 18:00)

Each was the library the design named (ErrorTracker, PlugAttack, Credo, Dialyzer, Sobelow, mix_audit). exqlite because a local, durable, transactional file is what the journal needs, and the receiver already relies on it for the same job (its spool); DETS was considered and rejected (no transactions, repair on unclean shutdown, 2 GB limit).

## Removal Requests

**Current:** A channel has a `public` flag: hidden, it disappears from every public page, list, leaderboard and data endpoint, and its data stays. "Delete all data" (the slug typed again) queues `Workers.DeleteChannel` on the collector, which stops tracking, deletes every row of the channel including its webhook events, then the channel, and resyncs subscriptions; the channel's Kick id goes into `removals` (as a privacy deletion's user id does), so an import can't bring it back, until an admin adds the channel again by hand. Every request to Kick carries a User-Agent naming the site and a contact (`KICK_USER_AGENT`, or built from `SITE_NAME`, `PHX_HOST`, `CONTACT_EMAIL`). (updated 2026-09-24 07:15)

Hiding first answers a streamer at once without losing anything if the request is withdrawn; deletion is the explicit second step. Deleting raw facts is, with privacy deletion, the only exception to append-only, and both are audited.

## Export and Import

**Current:** From `/admin/transfer` only (no command line). An export is a `.zip` written with Postgres `COPY`: `manifest.json` plus one CSV per table with a header row, keeping local ids so the files join for analysis as they are. Scope is the channel list alone (channels, slugs, groups, removals) or with history for an optional UTC date range; raw facts and admin corrections only (derived tables and admin accounts, audit log, settings stay). An import is uploaded, previewed from its manifest, then confirmed; the collector loads every CSV into a staging table (`LIKE <table> INCLUDING DEFAULTS`) and inserts through id maps built on natural keys, `ON CONFLICT DO NOTHING`, in one transaction, then queues a rollup rebuild over the imported range. A `removals` table (kind, Kick id) is written by privacy and channel deletions and travels with every export, so a removal on either side stays in force: removed channels aren't created, channels the other side removed are deleted here after the import, and removed users' rows are removed again with `Privacy.delete/1`. Files live in `TRANSFER_DIR` (a volume both roles mount) for 7 days. (updated 2026-09-24 17:00)

The owner wants to move and merge data between instances, share the channel list, and analyse data elsewhere, all from the admin UI. CSV serves all three: the same file re-imports and opens in a spreadsheet or pandas; `pg_dump` was ruled out because it can't merge into a database with its own ids and history. Merging on natural keys with existing rows winning keeps imports append-only and idempotent (AGENTS.md §7); overwriting on conflict would let a file silently change recorded history. `COPY` in and out keeps millions of rows fast and out of the BEAM's memory, and `:zip` streams large files (measured at ~80 MB resident for a 540 MB file). Mapping in SQL through staging tables rather than row by row in Elixir keeps a large import to a few statements. Imported open coverage periods are closed at the export's time, since the other collector stopped vouching for them then; per-user chat rows older than the 90-day retention are skipped. Known limit: if two collectors sessionized the same broadcast with different `started_at`, both streams are kept; merge them with a correction. Adding a channel by hand lifts its removal, since the admin chose to track it again.

## Backups

**Current:** WAL-G, compiled from source into the TimescaleDB image (`deploy/db`), archives WAL continuously (`archive_timeout` 60s) and takes a daily base backup (7 kept) to S3-compatible storage off the VPS, encrypted with libsodium. `deploy/backup/restore-test.sh` (weekly) restores the latest backup plus WAL into a scratch container and checks row counts against the live database and that recent streams' hours watched agree with their samples; failures alert, successes ping a heartbeat. (updated 2026-09-24 07:30)

WAL-G over pgBackRest: one static binary and native S3/B2/R2 support. The TimescaleDB image is Alpine, where WAL-G's release binaries (glibc) don't run, so it is built statically in a Go stage (`GOEXPERIMENT=jsonv2` is needed from v3.0.9). A sidecar reading a shared WAL directory was considered and rejected: more moving parts for the same result. The restore test was run locally against a file-backed WAL-G store; the first run caught a flaw in the test data, not the backup (an insert and `pg_switch_wal()` in one transaction put the commit in an unarchived segment).

## Deployment

**Current:** Two images built by CI (app, receiver) plus the database image; `compose.single.yml` for stage 1 and `compose.backup-receiver.yml` for stage 2; Caddy terminates HTTPS, restricts `/admin` to `ADMIN_ALLOW` networks, and fails the ingress over between two receivers (`lb_policy first`, active health checks). Two collectors (`collector-a`, `collector-b`), `restart: always`, 60s stop grace, each with its own journal volume and its own env file without web secrets; the app and collector images are pinned in `deploy/.env` (`APP_IMAGE`, `COLLECTOR_IMAGE`, required), written by the deploy workflow. A collector deploy updates the standby first (found from the collectors' status ports), waits for it to be healthy, then the leader. Migrations are their own `migrate` service run before a deploy, with `lock_timeout = 5s`. Secrets are sops + age encrypted env files; RabbitMQ's production definitions are generated on the server from them. The app listens on IPv4 unless `LISTEN_IPV6=true`; the receiver listens on `LISTEN_IP` (loopback in development, all interfaces in production). (updated 2026-09-24 18:00)

Checked here: both releases boot in the Debian runtime image (web served pages, assets and `/healthz`; the collector ran; `bin/migrate` ran), the Caddyfile validates, the compose file parses. The first release run failed binding `::` where IPv6 is off, as it would in many Docker hosts, hence IPv4 by default. The receiver bound loopback only, which Caddy in another container couldn't reach. Pinned images: with a `:latest` default, any plain `docker compose up -d` after pulling for a web deploy also recreated the collector; a required pin makes changing the collector a deliberate step. A separate env file keeps a web-only secret change from recreating the collectors, and keeps web secrets off them. The collector's container healthcheck used to be "always healthy"; it now asks the collector itself.

## CI/CD

**Current:** GitHub Actions. `ci.yml` on every push: per project (sim, receiver, app) format check, `--warnings-as-errors` compile and tests, with TimescaleDB and RabbitMQ from `deploy/compose.dev.yml`; for the app also Credo (defaults, nesting 3 and complexity 12), Sobelow (`.sobelow-conf`), `mix deps.audit`, `mix hex.audit`, an assets build, and Dialyzer in its own job with cached PLTs (`.dialyzer_ignore.exs` lists judged false positives with the reason). On `main`, the app, receiver and database images go to GHCR tagged with the commit and `latest`. `deploy.yml` is manual: pick a role (web, collector, receivers, migrate-only) and a tag; it runs migrations as their own step, then updates only that role, receivers one at a time waiting for each to be healthy. (updated 2026-09-24 07:45)

Deploys stay manual because a deploy is the moment collection can break; the button makes it one step without making it automatic. The compose file's image names follow CI's (`ghcr.io/<owner>/<repo>-<name>`). Sobelow's SQL findings were constant table names and bucket expressions, marked with `sobelow_skip` where they occur; its HTTPS check is ignored because Caddy terminates TLS.

## Security

**Current:** A Content-Security-Policy on every page with a per-request nonce for the one inline script (and for LiveDashboard and ErrorTracker), styles allowed inline (Tailwind, chart styles); rate limits with PlugAttack keyed on the visitor's address, read from `X-Forwarded-For` only when the request comes from a private address and only `TRUSTED_PROXY_HOPS` entries from the right; the admin behind Caddy's `ADMIN_ALLOW` networks plus password and TOTP. Failed admin logins are counted by our own entries in PlugAttack's ETS table, one per failure (20 in 10 minutes bans the address for an hour), not by PlugAttack's `fail2ban`. (updated 2026-09-24 20:00)

A browser check with the CSP on found no violations: charts (dynamic import), the LiveView socket and both dashboards work. Reading the leftmost `X-Forwarded-For` entry would let anyone choose their address and dodge limits; the rightmost-N rule trusts only what our own proxies appended. Login throttling plus a ban after repeated failures sits on top of TOTP, which already makes guessing hopeless, to keep the password hashing cost from being an easy load. `fail2ban` keys its sliding-window entries by the millisecond, so failures landing in the same millisecond overwrite each other: 20 failures fired at once counted as one, and a parallel burst was barely counted (it also made the ban's test fail about four times in five). A unique key per failure counts every one; the storage's cleaner expires them like its own rows.

## Data Quality

**Current:** `Metrics.Outliers` flags a reading that is 0 between two readings of 20 or more, or more than twice (and 50 above) both steady neighbours, only when both neighbours are within 150s; flags are derived (`viewer_flags`, recomputed with the rollups) and only change peaks. `Events.Shape` checks each stored webhook's type, version and the fields its handler reads; problems are counted per kind in `payload_issues` and alerted. The clock alert compares Kick's send time with our receive time (median over an hour, more than 30s). (updated 2026-09-24 07:45)

A glitch can't be told from a real event with one reading of context in general; these rules only catch the two shapes the design names and err towards not flagging (a raid that stays, a stream ending, a tiny channel's zero are all left alone, and tested). Excluding flags from averages was rejected: one reading barely moves an average, and dropping data from it would be an edit in disguise. Recorded webhooks all pass the shape check (a test), so a failure means Kick changed something.

## Development Approach

**Current:** Record real payloads once (anonymized into `fixtures/`), then build a fake Kick (`sim/`) with scenarios, fault injection and a bulk history mode before any tracking logic; all development and tests run against it, switched purely by configuration. (updated 2026-09-24 04:04)

Owner's requirement: develop without abusing Kick's endpoints and generate as much data as wanted. Also makes rare failures reproducible.

## Recorder

**Current:** Recorder as mix tasks in `sim/` (the future simulator's project), one per source, writing raw recordings to git-ignored `sim/recordings/` with secrets redacted at write time; `mix fixtures.anonymize` is the only path into `fixtures/`. Anonymization is rule-based by field name and context with a persisted real→fake mapping (every number under an `*_id` key is mapped except a small safe list; UUIDs and opaque string ids get consistent same-shaped fakes; JSON nested in strings is anonymized inside; our app's webhook subscription and message ids are kept because they must match the webhook headers), reports unmatched text fields by path for human review, and is followed by an independent leak check that searches the output for every real name, text and id from the raw files and fails the run if any is found. Pusher via Mint.WebSocket; webhook capture via Bandit + a response policy that can fail on purpose to observe Kick's retries. (updated 2026-09-24 04:55)

A generic "anonymize every string" approach was rejected: it would destroy event names, categories and languages the simulator needs. Rules + a report of what fell through keeps useful data and makes leaks visible. The leak check exists because the rules alone missed a real case on the first real data (`chatroom.chatable_id`, the channel id under an unexpected name); its criteria are deliberately simpler than the rules so a gap in them shows up. UUIDs were first kept as-is (to keep reply links); they're now mapped consistently instead, since a VOD's UUID points straight at the real channel's video and consistent mapping keeps the links anyway. Real signed webhook bodies stay only in `sim/recordings/` (anonymized bodies can't carry a valid Kick signature); the simulator signs with its own key. `websock_adapter` added as a test-only dependency for a local fake Pusher server; it will likely become a regular dependency when the simulator serves Pusher in phase 1.

## Undocumented Endpoints

**Current:** Probed once each (`mix record.probe`); none is part of the design yet. The follower count on `api.kick.com/private/v1/channels/{slug}` is the candidate replacement for v2 if v2 is blocked from the VPS; a channel's follower history uses one source only. Past streams (`api/v2/.../videos`, ~27 days, no viewer figures) and gift leaderboards are noted as possible later imports. (updated 2026-09-24 06:10)

The dedicated follower-count and viewer-count endpoints from the community list are gone (404). The private channel endpoint's count differed from v2's by 0.06% at nearly the same moment and uses different (opaque) ids, which is why sources are never mixed within one series. Endpoints needing a user login and personal profile data were excluded. The probe retries `api.kick.com` endpoints once with our app token on 401/403 but never sends it to kick.com; hosts come from configuration.

## Simulator Design

**Current:** Everything the fake Kick answers is a pure function of simulated time and the channel's seed (`Schedule`, `Curve`, `StreamState`, `Payloads`); processes only serve HTTP and deliver webhooks. One port serves all three Kick hosts. Payload shapes are checked against `fixtures/` in a test. (updated 2026-09-24 07:00)

Time-addressable state means the simulator can restart, be asked about the past, or run fast with no stored history, and it makes bulk history a writer over the same functions rather than a second simulation. One port keeps scenarios simple (three env vars, one base URL) and matches how the probe's end-to-end test already worked. The shape test against fixtures is what keeps "built from the fixtures" true over time rather than a one-off.

Bulk mode moved from phase 1 to phase 2: it writes the raw fact tables, which don't exist until the schema does.

## Simulated Event Rates and Shapes

**Current:** The simulator produces all ten documented event types. Rates scale with the audience and are tuned so a three-hour stream with a few thousand viewers gives hundreds of follows, tens of subs, a handful of mostly-small gift bursts, and a few bans and redemptions. Shapes for the seven event types not yet recorded follow Kick's documentation and are marked as such in `Sim.Payloads`. (updated 2026-09-24 08:00)

The first rates were far too high (a 9 000-viewer stream produced 3 400 follows and 1 000 gifted subs in three hours), which would have made any metric built against the simulator meaningless. Doc-based shapes are a deliberate exception to "don't write fixtures from the docs": they are simulator code, not fixtures, and the open question in §16 tracks re-checking them. `Sim.Webhooks.event_types/0` is the single list, used by both the simulator and `mix record.subscribe`, so a new event type is added in one place.

## Simulator Pusher and Delivery

**Current:** The fake Pusher runs on the simulator's port, speaks protocol 7 as Kick's chat uses it, and copies real Pusher's refusals (4001 wrong key, 4201 missed pong, 4200 via a fault). Webhook deliveries run concurrently, one task per attempt. Recorder writes use a VM-wide unique sequence number and an atomic rename. `websock_adapter` is a regular dependency now. (updated 2026-09-24 09:00)

Concurrent delivery matches Kick and matters: delivered one at a time, thousands of `chat.message.sent` webhooks held up a stream-end event. Making delivery concurrent then exposed a real recorder bug: sequence numbers taken from the folder's file count collided under concurrent writes, keeping only 20 of 200 files in a test; the real Kick delivers concurrently too, so a busy channel's recording could have lost webhooks. The low-rate recordings made so far show no sign of loss. Pusher `created_at` stays `+00:00` (not `Z`) because that's what the recording shows.

## Simulator Control

**Current:** Manual control (control API at `/_sim`, `mix sim.ctl`) works through overrides stored with each channel (streams started by hand, streams cut short, title/category changes), layered over the schedule in `Schedule` and `StreamState`. Scenario changes are pure functions in `Sim.Control`. Channel processes re-read their channel each tick. Control answers report events as `emitted`, not `delivered`. (updated 2026-09-24 10:00)

Flags set on processes would have broken the rule that the simulation is a function of time (restarts, history, fast clocks). Overrides keep it: a manual stream is just another window. A stream cut after it was first seen still reports its real end, because the end event resolves the window's current version. The first version said `delivered` for events that, with no webhook URL, went nowhere; a real run showed it, so the field was renamed. The control API has no auth: the simulator binds loopback only.

## App Skeleton

**Current:** Phoenix 1.8 app in `app/` (module `KickTracker`), Postgres 18 + TimescaleDB 2.30 and RabbitMQ 4 in `deploy/compose.dev.yml` on 127.0.0.1:55432 / 55672 (management 15673); the web port is 4100. `ROLE` (`collector`, `web`, or both) decides what a node starts; production must set it and every Kick URL, development and tests default to the fake Kick. `webhook_events.body` is `bytea` and `sent_at` verbatim text. Phoenix's generated `app/AGENTS.md` is kept, subordinate to the root one. (updated 2026-09-24 10:30)

Non-default ports because another local project already uses 4000 and Postgres ports vary; Phoenix's own `runtime.exs` set port 4000 for every environment. `bytea` because `jsonb` reformats JSON, and the stored delivery must still verify against Kick's signature; the plan had `jsonb`. TimescaleDB's compression SQL was checked on the running version before the migration (2.30 uses the `columnstore` names). Hypertable foreign keys to `channels` and `streams` are kept: correctness over the small insert cost. `categories` isn't created yet; `viewer_samples.category_id` is Kick's id without a foreign key until it is.

## Receiver

**Current:** `ingress/receiver` is its own Elixir app (Bandit, Plug, `amqp`, SQLite via `exqlite`). It verifies, builds the envelope, publishes with confirms and `mandatory`, spools to SQLite (WAL, `synchronous=FULL`) on any failure, and answers 200 only when the delivery is confirmed or on disk (503 otherwise). Returns are registered with `:amqp_channel` directly. RabbitMQ topology and least-privilege users come from `deploy/rabbitmq/definitions.dev.json`, with a `test` vhost mirroring development. (updated 2026-09-24 11:30)

Publishes go one at a time, which caps throughput around the broker's confirm latency; ample for webhook volumes (hundreds a minute at 1 000 channels) and it makes "the return in the mailbox belongs to this publish" true. The `amqp` library's return relay broke the return-before-ack ordering, so an unroutable message looked confirmed: found by a test, fixed by registering directly (verified 200/200). A closed channel made `wait_for_confirms` exit and crash the publisher; now caught, and a test asserts the same process survives. The spool deduplicates by message id, so Kick's retries don't pile up. Loading definitions removed RabbitMQ's default `guest` user, which is fine (one account fewer); the app now uses its own consume-only user.

## Queue Consumer

**Current:** `Events.Consumer` is Broadway on `broadway_rabbitmq`. Undecodable or wrongly signed messages are rejected to the dead-letter queue explicitly; everything else requeues. A batch is stored in one transaction; if the database is unreachable the batch waits and retries with backoff (messages stay unacknowledged); if one message breaks the transaction for another reason, the batch is stored one message at a time so only that one is dead-lettered. A missing Kick public key is waited out, not held against messages. (updated 2026-09-24 12:40)

The quorum queue dead-letters after 10 deliveries, so plain requeue-on-failure would dead-letter every good event during a short database outage: waiting inside the batcher keeps them in RabbitMQ instead. Facts that need no channel state are written in the same transaction; stream status and metadata are handed to the channel's process after the commit and stay unprocessed in `webhook_events` until it handles them (on start it catches up; `ProcessEvents` retries every 5 minutes, marking events of untracked channels processed).

## Metadata Changes

**Current:** The pure `Metrics.Changes` builds `stream_changes` for title, category, language and mature flag. A metadata event's snapshot is compared with the previous one; a snapshot older than the latest applied is ignored. The poll fills in missed changes but only counts a difference seen twice in a row, never within 120s of an event, dated at the first sighting. A stream's first values are recorded with no old value. A snapshot arriving before any stream is open is kept and applied when the next stream opens. (updated 2026-09-24 12:40)

The API lags Kick: right after a metadata event, the poll can still show the old title, and a naive comparison would record the title changing back and forth. Two sightings plus a quiet period after events removes that without losing changes whose events were missed (they are dated up to a minute late).

## Coverage

**Current:** `coverage` periods are always closed: each outcome extends the latest period for that channel and source if the result is the same and the previous outcome is recent (a little over the source's cadence), otherwise starts a new one. Sources: `api` (60s poll), `subscribers` (5-minute `/channels` poll), `chat`, `followers`, `ingress`. (updated 2026-09-24 12:40)

An open period (`to_at` null) would keep claiming coverage after a collector dies; closed periods make any time no period covers unknown, i.e. a gap, which is the invariant. Failed outcomes are stored too, so the site can tell "Kick didn't answer" from "we weren't running".

## Webhook Subscriptions

**Current:** `SubscriptionSync` (Oban, on every change to the tracked set and every 15 minutes) subscribes each active channel to the seven event types we use (status, metadata, follows, subs, resubs, gifts, Kicks), removes subscriptions of untracked channels, duplicates and unused types, and restores ones Kick cancelled. The delivery URL is set once in the Kick app's settings. (updated 2026-09-24 12:40)

A sync also runs when the collector boots, so a fresh collector gets its webhooks at once (found in the live run: it waited for the next cron). Kick's subscription API takes a broadcaster, event types and `method: webhook`, with no URL, so "pointing at the ingress URL" in the plan is an app setting, not code. Bans, redemptions and chat aren't subscribed: nothing reads them (chat comes from Pusher).

## Jobs

**Current:** Oban runs on every node; its queues (`kick`, `followers`, `alerts`, `transfers`) start paused and run only on the leading collector, which resumes them when it takes the lease and pauses them when it gives it up (checked every tick, locally). A web node and a standby only insert jobs. Cron (inserted by whichever node Oban elects): `SubscriptionSync` every 15 minutes, `ProcessEvents` every 5, `Alerts` every minute (its own queue, so long jobs can't delay it), rollups. Every worker has a time limit. (updated 2026-09-24 18:00)

Admin actions on the web node need to enqueue work the collector runs; one Oban config with leadership deciding where queues run keeps that simple, and keeps jobs that write collected data where collection runs. Pausing and resuming go through Oban's notifier, so each tick re-checks the queues' local state and repeats what a database blip may have dropped.

## Timestamps

**Current:** Every time column is `timestamptz`. (updated 2026-09-24 12:40)

Ecto's `:utc_datetime_usec` migration type creates `timestamp without time zone`, which the first migrations used by mistake although the design says `timestamptz`; raw SQL then returned naive datetimes. Nothing was deployed, so the migrations themselves were corrected and the local databases rebuilt, rather than adding an alter migration.

## Simulator as a Dependency

**Current:** The app depends on `../sim` as a path dependency in dev and test only. Integration tests start a fake Kick on a free port and point the app's Kick configuration at it; bulk mode will use its schedule and curves. (updated 2026-09-24 12:40)

Tests then exercise the real HTTP paths (token, public API, subscriptions, Pusher) with no mocks, and control the fake Kick directly (clock, token expiry, going offline). It never reaches production builds.

## Facts from Events

**Current:** Follows, subs, resubs, gifted subs and Kicks are parsed by the pure `Events.Facts` and written in the same transaction that stores the event, only for tracked channels. They carry no stream id; stream attribution is by time at read time. Usernames go only to `kick_users` (a later sighting's name wins). Kicks messages are never read. (updated 2026-09-24 13:10)

The plan had `stream_id NULL` on these tables, set at write time. That makes the result depend on arrival order: a follow stored before its stream's start event would be attributed to no stream forever (raw facts are never updated). Attributing by `occurred_at` against stream ranges is the same answer in any order and survives a stream's end being corrected. The sub, gift and Kicks parsers follow Kick's documentation and the simulator's shapes; they must be re-checked when those events are recorded (§16).

## v2 Fields

**Current:** From v2 the app reads `followers_count` and `chatroom.id`, in `Kick.V2`, and drops the rest there. AGENTS.md §6 was updated to say so. (updated 2026-09-24 13:10)

Chat (Pusher) needs the chatroom id, which differs from the channel and user ids and appears in no official endpoint; §12.2 already planned storing it as a channel attribute. The owner's rule said "followers_count only"; the rule's purpose (never keep the signed playback URL, keep v2 isolated) is unchanged. Flagged to the owner for confirmation.

## Follower Readings

**Current:** A polled source (`Collector.Sources.Followers`) reads v2: every 15 minutes while live, daily while offline, one channel per request, one at a time, three per 15-second cycle; a failed reading is a gap and is retried 10 minutes later. Requests (a stream's start and end, a channel added) are served within a second; from a web node they travel as a `FollowerPoll` job, which runs on the leader and hands the request over. When each channel was last read is loaded from the database once, and kept in memory after. (updated 2026-09-24 18:00)

Replaced the Oban `FollowerPoll`-per-reading plus `FollowerSchedule` pair: as a source it gets the runner's cadence, isolation, coverage and journaled writes like the other sources, and no longer needs the database to decide or to write. The per-cycle limit replaces the random delays that kept v2 from seeing bursts.

## Rollups

**Current:** `stream_stats` and `hourly_stats` are caches recomputed by an Oban job (last 3 hours every 5 minutes, last 48 hours nightly) and by `mix kick_tracker.rebuild`, not TimescaleDB continuous aggregates. Hours watched: each sample weighs the time since the previous sample of its stream (the first, since the stream's start), capped at 75s; `KickTracker.Metrics` is the reference and the SQL rollup is property-tested to agree with it. Stream figures count follows, support and chat by time between start and end. Follower gain uses the readings closest to the start and end, within 30 minutes, else null. (updated 2026-09-24 14:10)

Continuous aggregates can't use window functions, and Σ viewers × min(Δt, 75s) needs each sample's neighbour; Toolkit's time-weighted averages aren't in the community image. Approximating hourly hours watched as Σ viewers × 60s would make hourly and per-stream figures disagree. A backward weight puts each sample's contribution in the hour it was taken, so hourly figures add up exactly to the stream's. Recompute-by-range caches are also cheap to change when a formula changes, which continuous aggregates are not.

## Bulk Mode

**Current:** `KickTracker.Bulk` and `mix kick_tracker.bulk` live in `app/dev/`, compiled only in dev and test, and write a scenario's history straight into the raw tables from the simulator's pure functions: streams closed by an end event, a sample every 60s at a per-stream offset, change logs from `StreamState` segments, facts from `Events.for_minute` (message ids `bulk:…`), chat bucketed by clock minute, followers (15 min live, at start and end, noon on other days), subscribers every 5 minutes, one coverage period per source; then the rollups. Only streams that ended before `to`. Idempotent (inserts ignore existing rows). (updated 2026-09-24 14:40)

A path dependency on `../sim` limited to dev/test, plus a dev-only source directory, keeps the simulator out of production builds entirely. Writing rows directly instead of replaying webhooks through the pipeline makes months of history take minutes; the pipeline itself is covered by the integration tests. Bulk facts have no `webhook_events` rows, so they can't be rebuilt from events: acceptable for development data only.

## Unknown Is Null

**Current:** Derived figures with no underlying data are null, not zero: `avg_viewers`, `peak_viewers` and `hours_watched` in `stream_stats` and `hourly_stats` when there are no viewer samples; follower totals and gain without a reading near the start or end. (updated 2026-09-24 14:40)

A zero would read as "nobody watched" when it means "nothing was measured", the same mistake "gaps are gaps" forbids for raw data. Readers use `samples` and `coverage` to tell an offline hour from an unmeasured one.

## Testing Strategy

**Current:** Tests written alongside each feature; unit + property tests for the pure core, fixture-based parser tests, integration tests against the simulator with real TimescaleDB and RabbitMQ. (updated 2026-09-24 04:04)

## Phase Order

**Current:** 0 record → 1 fake Kick → 2 pipeline → 3 admin core → 4 public site → 5 backups, alerts, legal, then real collection → 6 CI/CD, data quality, security. (updated 2026-09-24 04:04)

Owner's ordering: operations and legal after core works but before real collection; hardening last.
