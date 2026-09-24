# kick_tracker

A website that tracks the stats of a chosen set of Kick channels over time:
viewers, airtime, hours watched, followers, chat activity, subs and Kicks,
and the figures derived from them. The model is sites like Streams Charts,
limited to channels we pick: a handful at first, able to grow to hundreds or
low thousands.

The one thing that decides whether this is any good: **history only exists
from the moment we start recording it.** Kick serves the present, never the
past, and webhook events we miss are gone for good. The collector has to run
continuously and without gaps from day one; the website is the easy part.

---

## 1. Authorization

- **Public stats of any channel need no permission from the channel owner.**
  We register one app with Kick and use an **app access token**
  (OAuth client-credentials grant, `id.kick.com`). Only we are involved.
- The same app token can **subscribe to webhook events for any channel** by
  passing `broadcaster_user_id` (the docs: app tokens "have full permission";
  a user token needs the `events:subscribe` scope and only covers its own
  channel).
- A **user access token** (authorization code + PKCE, the owner logs in and
  approves scopes) is only needed to act for someone (send chat, moderate,
  edit the channel) or to read private data. Nothing in this project needs it
  unless we later add private metrics.

## 2. Where the data comes from

Four sources, each used for what only it does well.

### 2.1 Official public API: polling

`https://api.kick.com/public/v1`, documented, app token.

- `GET /livestreams`: `viewer_count`, `started_at`, `stream_title`,
  category, language, tags, mature flag. Up to **50 channels per request**
  (`broadcaster_user_id` repeated). Also filters by `category_id` and
  `language`, sorts by `viewer_count`, `limit` up to 100: usable later for
  category rankings.
- `GET /channels`: slug, broadcaster id, title, category, `stream` (is_live,
  viewer_count, start time, language, tags), description, banner, and
  **subscriber counts** (`active_subscribers_count`,
  `active_gifted_subscribers_count`, `canceled_subscribers_count`). Up to
  **50 per request**, by id or by slug (not mixed). **No follower count.**
- Back off on 429.

Observed in the recordings (2026-09-24, `sim/recordings/`):

- **`viewer_count` changes about once a minute** (median 61s between
  changes, shortest 46s, over 40 polls at 15s). Polling every 15s saw each
  value about four times, so viewers are polled **every 60s** (§3.1): peaks
  and averages can't be finer than Kick's own refresh anyway.
- **Subscriber counts are filled for a channel that hasn't authorized us**
  (real non-zero values with the app token). `stream.key` and `stream.url`
  are empty strings.
- **An unknown slug fails the whole request** with 400 `Invalid request`, not
  an empty result. Slugs are checked one at a time when a channel is added;
  batched calls use broadcaster ids.
- **Offline** `/livestreams` answers 200 `{"data": [], "message": "OK"}`.
- **No rate-limit headers** in any response; the limits stay unknown.
- App tokens last **60 days** (`expires_in` 5 184 000).
- The API lags the real end of a stream by a few seconds: live 3s after
  `ended_at`, empty 19s after.

### 2.2 Official webhooks: events

`POST /public/v1/events/subscriptions` with the app token and
`broadcaster_user_id`, one subscription per channel per event type.

| Event | Gives | Used for |
|---|---|---|
| `livestream.status.updated` | `is_live`, title, `started_at`, `ended_at` | Stream start and end, within seconds |
| `livestream.metadata.updated` | title, language, category | Title and category changes |
| `channel.followed` | each new follow | Exact gross follows (no totals, no unfollows) |
| `channel.subscription.new` | subscriber, duration, expiry | New subs |
| `channel.subscription.renewal` | subscriber, duration, expiry | Resubs, months subbed |
| `channel.subscription.gifts` | gifter (may be anonymous), giftees | Gifted subs |
| `kicks.gifted` | sender, amount, gift type and tier | Kicks |
| `moderation.banned` | bans and timeouts | Not tracked; must be tolerated |
| `channel.reward.redemption.updated` | channel-point redemptions | Not tracked; must be tolerated |
| `chat.message.sent` | every chat message | Not used for now, see §2.4 |

These ten are every event type Kick documents. Captured so far:
`livestream.status.updated`, `livestream.metadata.updated` and
`channel.followed`. The rest are still to record (§16); the simulator
produces all of them, the unrecorded ones from Kick's documented field
lists rather than from a recording.

- Limits: 10 000 subscriptions per event type per app; `chat.message.sent`
  is capped at 1 000 for apps Kick hasn't verified.
- No viewer-count event and **no raid or host event**.
- Requires a **public HTTPS endpoint**, **signature verification** against
  Kick's public key, and **idempotent handling** (the same event can arrive
  twice; key on Kick's message id). The endpoint is the **ingress** (§8), not
  the app.
- Delivery headers: `Kick-Event-Message-Id` (ULID), `Kick-Event-Subscription-Id`,
  `Kick-Event-Signature` (base64), `Kick-Event-Message-Timestamp` (RFC 3339),
  `Kick-Event-Type`, `Kick-Event-Version`. The signature covers
  `message_id.timestamp.raw_body`, signed with Kick's private key.
- "If an app's webhook continually fails to process an event for over a day,
  Kick automatically unsubscribes the app from that event." Retries are
  implied but not documented (§16).
- **Webhooks we miss are lost.** Stream state and metadata can be recovered
  by polling (§2.1); subs, gifts, Kicks and follows cannot. Ingress downtime
  is recorded as a coverage gap (§12).
- Local development needs a tunnel (cloudflared or ngrok) so Kick can reach
  the ingress.

Observed in the recordings (2026-09-24):

- **All 9 event types were accepted with the app token** for a channel that
  hasn't authorized us (`livestream.*`, `channel.followed`,
  `channel.subscription.*`, `kicks.gifted`, `moderation.banned`,
  `channel.reward.redemption.updated`). Deliveries seen so far: follows,
  status, metadata; subs, gifts and Kicks not observed yet.
- **Start and end are the same event type**, `livestream.status.updated`:
  start has `is_live: true, ended_at: null`, end has `is_live: false` and
  `ended_at`. Both carry the same `started_at`, and it is **string-identical
  to `/livestreams`' `started_at`** (`YYYY-MM-DDTHH:MM:SSZ`, second
  precision). Stream length = `ended_at − started_at`.
- The `title` in status events is the title **at that moment** (the end event
  had the changed title), so status events are not a source of title changes.
- **`livestream.metadata.updated` is a full snapshot** (title, language,
  `has_mature_content`, category), sent whenever any of them changes; which
  field changed is found by comparing with the previous snapshot. The
  category appears **twice**, as `category` and `Category`, with the same
  value; we read the lowercase one.
- **`livestream.metadata.updated` and `channel.followed` carry no timestamp**
  in the body; when it happened comes from `Kick-Event-Message-Timestamp`
  (`...Z`, second precision).
- **Delivery is fast**: 0.2–0.9s after Kick's timestamp; the end event arrived
  5s after `ended_at`. Every delivery's signature verified.

### 2.3 Private v2 API: follower totals only

`https://kick.com/api/v2/channels/<slug>`, Kick's own frontend API (the one
KickPlus uses). The only source of the **total follower count**
(`followers_count`).

- Tested with a plain `curl` from a home machine: **200**, with a
  `followers_count` for a test channel matching what Streams Charts showed.
- Undocumented, can change, and Cloudflare is often stricter with datacenter
  IPs: **test from the VPS before relying on it**.
- Light use only: one channel per request, every 15 min while live and once a
  day offline (§3).
- Read `followers_count` and discard the rest. The response also carries a
  `playback_url` with a signed token; it is never stored.
- Isolated in its own module so it can be replaced. Failures are gaps, never
  zeros; `channel.followed` keeps counting gross follows meanwhile.
- Observed (2026-09-24): 200 with `followers_count` from a home machine; the
  datacenter test is still open. The response repeats the channel id under
  `chatroom.chatable_id`. `followers_count` came as a **number in one
  recording and a string in another**: parse both.

### 2.3b Other undocumented website endpoints (probed)

The community list fb-sean/kick-website-endpoints documents Kick's website
API. Same status as v2: undocumented, can change, a grey area under Kick's
terms; used only isolated and optional, failures are gaps. `mix
record.probe` requested each read-only candidate once for one live channel
(2026-09-24, from a home machine, no auth unless noted):

| Endpoint | Result | Use |
|---|---|---|
| `api.kick.com/channels/:id/followers-count` | 404 (by user id and by channel id) | Gone |
| `api.kick.com/private/v0/channels/:id/viewer-count` | 404 | Gone |
| `api.kick.com/private/v1/channels/{slug}` | **200** | **Possible v2 replacement for the follower total** (below) |
| `api.kick.com/private/v1/livestreams` | 200: all of Kick's live streams, sorted by viewers, 20 per page, cursor | Rankings; the official `/livestreams` (sorts by viewers, 100 per page) is preferred |
| `kick.com/current-viewers?ids[]=` | 200: `[{livestream_id, viewers, show_view_count}]` | Several streams' viewers in one call; not needed while the public API works |
| `kick.com/api/v2/channels/{slug}/leaderboards` | 200: top gifters all time (10), month (10), week (5) | **Partial gift history from before tracking**; a cross-check for our gift counts |
| `kick.com/api/v2/channels/{slug}/videos` | 200: the last ~27 days of streams (14 here) | **Airtime history from before tracking** (below) |
| `kick.com/api/v1/channels/{slug}` | 200 (51 KB): same past streams under `previous_livestreams`, `followersCount` equal to v2's | Alternative to the two above |
| `kick.com/api/v2/channels/{slug}/clips` | 200: clips with `view_count`, `likes_count`, cursor | A later clips feature |
| `kick.com/api/v2/channels/{slug}/livestream` | 200: live stream details, `viewers` | Not needed |
| `kick.com/api/v2/channels/{slug}/chatroom` | 200: chat settings (followers-only, slow mode…) | Maybe later, as context on chat activity |
| `kick.com/api/v2/channels/{slug}/subscribers/last` | 401 (needs a login) | Not usable |
| `…/videos/latest`, `private/v1/channels/{slug}/clips` | 404 | Gone |

What that means:

- **`private/v1/channels/{slug}` as a follower source.** It answers on
  `api.kick.com` without auth, so it may avoid v2's Cloudflare risk from a
  server. But its count was **0.06% higher than v2's** at almost the same
  moment (v1 and v2 agreed exactly), and it uses **opaque string ids**
  (`channel_…`, `user_…`), not Kick's numeric ids. So: a channel's follower
  history comes from **one source only**, never mixed. The probe from the
  VPS decides which (§16).
- **Past streams (`videos`)**: start time, `duration` in **milliseconds**,
  title, categories, VOD views, for about the last month. `viewer_count` is
  **0 for every finished stream**: no viewer history. When a channel is
  added, about a month of airtime and category history could be imported,
  marked as imported, never mixed with observed data. Not planned yet.
- **Leaderboards** are top lists, not every gift, so they can't become a
  full history; they're for display and checking.

### 2.4 Pusher websocket: chat, raids and hosts (unofficial)

`wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false`,
subscribe to `chatrooms.<chatroom id>.v2` with `auth: ''`.

- The same public feed kick.com's own chat uses; the app key ships to every
  visitor. KickPlus already uses it for its active-chatters line.
- No account or token; should work from a server.
- `App\Events\ChatMessageEvent` carries `sender.id` and `sender.username`.
- Also carries host/raid events (event names to confirm), and possibly other
  events on the per-channel feed `channel.<id>` (to verify).
- Observed (2026-09-24, from a home machine):
  - Accepted without auth; subscribing to `chatrooms.<id>.v2` and
    `channel.<id>` both succeed.
  - **The server's first frame (`connection_established`) often arrives in
    the same read as the upgrade response.** A client must process those
    bytes or it never subscribes (the recorder had this bug; fixed and
    tested).
  - `App\Events\ChatMessageEvent` has `type` `message` or `reply`; a reply
    carries `metadata.original_message` (id, content) and
    `metadata.original_sender` (id, username), plus `thread_parent_id`.
    Message ids are UUIDs. Senders carry `identity.badges_v2`.
  - Nothing arrived on `channel.<id>` in 20 minutes besides the subscription
    confirmation. No raid or host seen yet.
- Chat stays here rather than on the chat webhook: a webhook is one HTTP
  request per message, heavy on busy channels, and capped at 1 000 channels
  for an unverified app. The webhook is the official fallback if Pusher stops.
- Unofficial: it depends on an app key Kick doesn't offer to third parties.
  Everything else keeps collecting if it stops.

## 3. What we track

### 3.1 While a channel is live

| What | How | Cadence |
|---|---|---|
| Stream start and end | `livestream.status.updated`; Kick's own `started_at` / `ended_at` | Event |
| Viewers | `GET /livestreams`, batched | **Every 60s** (Kick refreshes about every 60s, §2.1) |
| Title changes | `livestream.metadata.updated` (+ compared on each poll) | Event |
| Category changes | `livestream.metadata.updated` (+ compared on each poll) | Event |
| Active chatters | unique senders per minute, per user (§12) | **Per minute** |
| Hosts and raids | Pusher events | Event |
| Followers (total) | v2 `followers_count` | **Every 15 min**, plus **at stream start and end** |
| Subscribers (active, gifted, cancelled) | `GET /channels` (the safety-net poll) | **Every 5 min** |
| Follows | `channel.followed` | Event |
| Subs, resubs, gifted subs | `channel.subscription.*` | Event |
| Kicks | `kicks.gifted` | Event |

### 3.2 While offline

| What | How | Cadence |
|---|---|---|
| Followers (total) | v2 `followers_count` | **Once a day** |
| Subscribers (active, gifted, cancelled) | `GET /channels` (the safety-net poll) | **Every 5 min** |
| Going live | `livestream.status.updated` | Event |
| Safety-net poll | `GET /channels`, batched, all channels | Every 5 min |
| Follows, subs, gifts, Kicks | webhooks | Event |

### 3.3 Stream identity

- **Start:** Kick's `started_at`. **End:** Kick's `ended_at`, or the last live
  reading if the event was missed (accurate to 60s).
- **Kick sends no livestream id**: neither `livestream.status.updated` nor
  `GET /livestreams` carries one. A stream is identified by
  **`(channel_id, started_at)`**, Kick's own start time, which both the
  webhook and the poll report. A brief disconnect Kick treats as the same
  stream keeps its `started_at` and stays one stream; a new `started_at`
  starts a new one. v2's livestream id may be stored as an extra, never
  relied on.
- **Confirmed on real data**: the start event, the end event and the API
  poll all reported the identical `started_at` string for the same stream.
- The safety-net poll opens or closes streams whose webhooks were missed.

### 3.4 Chat windows are chosen at read time

Unique chatters don't add up: someone who writes in minutes 1, 2 and 3 is
1+1+1 = 3 in per-minute counts but 1 over the three minutes. So chat is kept
at two levels of detail (§12.3):

- **per minute per chatter** (`chat_minute_users`, kept 90 days): any window
  inside a stream is one `COUNT(DISTINCT user_id)` over that stream's rows:
  active chatters per 5, 10, 15 minutes, or rolling (like KickPlus).
- **per stream per chatter** (`chat_stream_users`, kept): unique chatters per
  stream, day, month; returning vs new; overlap between channels; top
  chatters.

Windows inside a stream only read one stream's rows; everything over days or
months reads the per-stream table, 20–50× smaller. The 90-day limit on the
per-minute table loses no long-term statistic.

## 4. Metrics

### 4.1 Read directly

| Metric | Source |
|---|---|
| Live / offline, start and end time | webhook, poll as backup |
| Viewers | public API, every 60s |
| Title, category, language, tags | webhook + public API |
| Follower total | v2 |
| Subscriber totals (active, gifted, cancelled) | public API `/channels` |
| Follows | webhook |
| Subs, resubs, gifted subs, Kicks | webhooks |
| Chat messages (sender, time) | Pusher |
| Hosts and raids | Pusher |

### 4.2 Derived from raw facts

Kick provides none of these; each is computed from the raw tables (§12) and
can be recomputed if a formula changes.

| Metric | How |
|---|---|
| Airtime, number of streams, active days | stream start and end |
| Average viewers | mean of viewer samples while live |
| Peak viewers | highest sample (60s resolution, Kick's own refresh rate) |
| Hours watched | Σ viewers × min(Δt, 75s) |
| Viewer curve per stream | the raw samples |
| Viewers / hours watched / time per category | samples grouped by the category they carry |
| Title and category impact | viewer samples around change events |
| Follower gain (per stream, period) | follower totals at start and end; gross follows from webhook |
| Subscriber growth, gifted share, cancellations | subscriber samples over time |
| Active chatters (any window), messages, unique chatters | chat minutes |
| Engagement rate | chatters ÷ viewers |
| New vs returning chatters, overlap between channels | chat minutes across streams and channels |
| Subs, gifted subs, Kicks per stream, day, hour watched | support events |
| Top gifters and supporters | support events |
| Raid impact | viewer samples around raid events |
| Day-of-week analysis, lifetime totals, rankings | the above, grouped |

All of these cover only the period since we started tracking a channel.

### 4.3 With limits

- **Subscriber totals** come from `/channels` every 5 minutes (active,
  gifted, cancelled), so they're known at that resolution; who subscribed,
  and when exactly, comes only from the webhook events we received.
- **Revenue:** Kicks and subs have known prices, so money figures are
  possible, but only as labeled **estimates** (Kick's cut, regional pricing).

### 4.4 Not obtainable from Kick

- **Audience demographics** (country, gender, age, interests): Kick doesn't
  publish them. Only an estimation model could give these.
- **Personal facts** (real name, birthday, city, business email): not in any
  API. Manual entry only, if wanted at all.

## 5. Reference: how Streams Charts does it

From one channel's page on streamscharts.com (behind Cloudflare, so
read from screenshots):

- **Snapshot data:** live status, title, category, current viewers, followers
  (26K), partner badge, language.
- **Computed from their sampling:** 30-day airtime (119h 5m), average viewers
  (612; 619 lifetime), peak viewers (18K on 04 Oct 2025), hours watched per
  category (39 907 in Just Chatting, 94.7% of HW), per-stream averages and
  viewer sparklines, day-of-week breakdown, lifetime airtime (2 588h) and
  active days (588), follower gain per stream (best stream +348).
- **Multistreaming:** the Kick channel is matched to a YouTube channel and
  both are sampled; a manual or heuristic link.
- **Not from Kick:** the audience block (top country, gender, age range,
  with locked percentages) is modeled; the "About" block (real name, birthday, age,
  business email, socials) is crowd-sourced or entered by the streamer (it has
  an Edit button).
- **Not real data:** the "growth by week" chart is labeled
  "DEMO · SAMPLE DATA" and starts in 2020, before Kick existed (end of 2022).
  Hours watched / peak / follower gain showing 0 next to 612 average viewers
  and 119h airtime are locked free-tier values, not zeros.
- Their numbers never quite match other analytics sites because each only
  knows what its own sampling saw.

## 6. Scale and load

Estimates, not measurements: ~4h of streaming per channel per day, about 20%
of channels live at any moment, ~20 unique chatters per minute and ~300
unique chatters per stream on average, no chat text stored.

| | 10 channels | 100 channels | 1 000 channels |
|---|---|---|---|
| Viewer rows/day (60s) | ~2.5k | ~25k | ~250k |
| Chat minute × chatter rows/day (kept 90 days) | ~50k | ~500k | ~5M |
| Chat stream × chatter rows/day (kept) | ~3k | ~30k | ~300k |
| Stored after the first year, compressed | ~0.1 GB | ~1 GB | ~10 GB |
| Open chat websockets | 10 | 100 | 1 000 |
| Chat messages/s at peak | ~5–50 | ~50–500 | ~500–5 000 |
| Viewer polls (public API) | 1 req / min | 1 req / min | ~4 req / min |
| Safety-net polls | 1 req / 5 min | 2 req / 5 min | 20 req / 5 min |
| v2 follower requests | < 1 / min | ~1–2 / min | ~15 / min |
| Webhook subscriptions | ~80 | ~800 | ~8 000 (limit 10 000 per type) |

- Everything fits on one small server.
- Per-minute chatter rows are the largest table; the 90-day retention caps
  them. After that, growth is mostly viewer samples and per-stream chatters.
- If distinct counts ever get slow, mergeable counters (HyperLogLog, roaring
  bitmaps) or a ClickHouse copy of the raw tables (§12.1) are the next steps.
- v2 is one request per channel; spread over time, never in bursts.

## 7. Why Elixir / Phoenix

Compared against Go and Bun (Node-style):

| | Elixir / Phoenix | Go | Bun |
|---|---|---|---|
| One worker per channel | Supervised process, built in | Goroutine, supervision written by hand | Objects on one shared event loop |
| One channel fails | Only its process restarts | A panic kills the program unless every goroutine recovers | An uncaught error can stop every channel |
| One busy channel | Scheduler shares CPU fairly | Uses all cores | Blocks every channel |
| Many websockets | Excellent | Excellent | Good |
| CPU throughput | Moderate, enough here | Best | Good, one core by default |
| Live updates to the browser | LiveView + PubSub, nothing extra | Hand-written SSE/websockets + separate frontend | Collector and Next.js need a relay (LISTEN/NOTIFY, Redis) |
| More than one server | Built-in clustering (libcluster, Horde) | Shard the channel list by hand | Shard by hand |
| Background jobs | Oban (Postgres), mature | Hand-rolled | Hand-rolled or BullMQ + Redis |
| Queue consumption | Broadway, with an official RabbitMQ producer | Libraries, hand-wired | Libraries, hand-wired |
| Deployment | `mix release` | One static binary | Container, web on Node |
| Ramp-up | Steepest (OTP) | Moderate | Lowest |
| Codebases | 1 | 1–2 | 2 runtimes |

The problem (many long-lived connections, per-channel state, must never
silently stop, live dashboards) is what the BEAM was built for, and Phoenix
covers the website in the same project. The cost is learning OTP.

## 8. Architecture: ingress, queue, app

The outside world pushes, the queue holds, the app pulls.

```
                 INGRESS  (replaceable; redundancy lives here)
Kick ──webhook──▶ receiver(s) ──publish──▶ RabbitMQ
                  - verify signature         exchange kick.events
                  - wrap in envelope         queue    kick_tracker.events (quorum)
                  - spool to disk if the
                    queue is unreachable
                                                  │ consume
                 APP  (unchanged whatever the ingress is)
                                                  ▼
                  Broadway consumer ──▶ webhook_events (DB, permanent) ──▶ processing
                  - re-verify signature
                  - ack only after the DB commit
```

- The app's **only** view of pushed data is the queue. Who received the
  events, how many receivers there are and where they run is a deployment
  choice, changed without touching the app.
- The app needs **no public endpoint**: it connects out to RabbitMQ. Only the
  ingress faces the internet.
- Data the app fetches itself (polling, v2, Pusher) does not go through the
  queue; there is nothing to buffer.
- `SubscriptionSync` registers the **ingress URL** with Kick. For the app it
  is a config value, nothing more.

### 8.1 The envelope (the contract)

Every ingress produces exactly this, as the message body (JSON). The full
definition, transport properties and versioning rules are in
[`contracts/envelope.md`](contracts/envelope.md), with a JSON schema.

```json
{
  "envelope_version": 1,
  "message_id": "01J…",        // Kick-Event-Message-Id (the dedup key)
  "subscription_id": "01J…",   // Kick-Event-Subscription-Id
  "event_type": "livestream.status.updated",   // Kick-Event-Type
  "event_version": "1",        // Kick-Event-Version
  "sent_at": "…",              // Kick-Event-Message-Timestamp, verbatim
  "signature": "…",            // Kick-Event-Signature
  "body": "<raw request body, byte for byte>",
  "received_at": "…",          // ingress clock, RFC 3339 UTC, microseconds
  "receiver": "vps-a/1"
}
```

`message_id`, `sent_at` and `body` are copied exactly, since together they
are the signed text (`message_id.sent_at.body`, RSA SHA-256 PKCS#1 v1.5).
A body that isn't valid UTF-8 travels as `body_base64` instead. The
envelope's own `envelope_version` is separate from Kick's `event_version`.

AMQP properties: `message_id` = Kick's message id, `type` = event type,
`delivery_mode` = persistent, routing key = event type.

The raw body and signature travel with it, so the app verifies again and
trusts neither the queue nor the ingress. Every ingress has a test
producing envelopes that validate against the schema.

### 8.2 What the app may assume, and nothing more

1. **At-least-once delivery.** Any event can arrive more than once; the app
   ignores repeats by `message_id`.
2. **No ordering.** "Offline" can arrive before the "online" it follows. The
   app uses the event's own timestamps and the stream's `started_at`, never arrival
   order.
3. **Ack after commit.** A message is acknowledged only once the app has
   saved it. A crash before that means redelivery.
4. **Short queue retention.** The queue is a buffer, not a record.
   `webhook_events` in the app's database is the permanent record, and every
   metric can be recomputed from it.

Any ingress and queue that honor these can replace the current ones. On the
app side only the Broadway producer and its config change.

### 8.3 RabbitMQ setup

- **Exchange** `kick.events`, type `topic`, durable. Routing key = event
  type (`livestream.status.updated`, `kicks.gifted`, …).
- **Queue** `kick_tracker.events`, **quorum queue** (replicated when the
  broker is clustered, durable on disk), bound with `#`. Other consumers
  (analytics, experiments) can later bind their own queues to the same
  exchange without affecting this one.
- **Dead letters:** exchange `kick.events.dlx` → queue `kick_tracker.events.dead`.
  A message goes there after the quorum queue's `x-delivery-limit` (e.g. 10)
  or when the app rejects it as undecodable or wrongly signed. Dead letters are
  inspected and replayed by hand, never dropped silently.
- **Publisher confirms** on the receiver side: a receiver answers Kick 200
  only after RabbitMQ confirms the message, or after it is written to the
  local spool.
- **No built-in deduplication:** two receivers may publish the same event;
  the app's unique `message_id` makes it harmless.
- **Separate users:** receivers may only publish to `kick.events`; the app may
  only consume from `kick_tracker.events`.
- Management plugin on, reachable only over the private network.

### 8.4 Ingress: the self-hosted receiver

A small, separate Elixir app (Bandit + Plug + the `amqp` client), deployed on
its own and rarely changed:

1. Read the raw body and the `Kick-Event-*` headers.
2. Verify the signature with Kick's public key. Reject if invalid.
3. Build the envelope.
4. Publish with confirms. If RabbitMQ is unreachable or doesn't confirm in
   time, append to the **local spool** (SQLite on the receiver's own disk).
5. Answer 200.

A forwarder in the same app drains the spool into RabbitMQ when it is
reachable again. It needs only Kick's **public** key and publish-only
RabbitMQ credentials: no app secret, no database access.

Later ingress options (same envelope, same exchange or an equivalent queue):
a Cloudflare Worker, managed RabbitMQ (CloudAMQP: no app change at all), or
another queue with its own Broadway producer.

## 9. Tech stack

| Part | Choice | Why |
|---|---|---|
| Language / runtime | **Elixir** (1.18+) on **OTP 27+** | Supervised processes, fault isolation, fair scheduling, runs for months. |
| Web | **Phoenix + LiveView** | Same codebase as the collector; pages subscribe to live readings over PubSub. |
| Queue | **RabbitMQ** (quorum queues, publisher confirms, dead-lettering) | Mature, runs on the BEAM, official Broadway producer; managed options exist (CloudAMQP). |
| Queue consumer | **Broadway** + **broadway_rabbitmq** | Batching, acks, back-pressure, concurrency; the queue is a swappable producer. |
| Receiver | **Bandit + Plug + amqp**, **SQLite** spool (exqlite) | Tiny, separate, rarely redeployed. |
| HTTP client | **Req** | Public API, v2, token endpoint. Retries and backoff built in. |
| Chat websocket | **Mint.WebSocket** inside our own GenServer (or WebSockex if simpler) | Maintained, the process owns the connection, reconnect logic is ours. |
| JSON | **Jason** (or OTP's `:json`) | Chat frames, API bodies, envelopes. |
| Database | **PostgreSQL + TimescaleDB**, one database | Hypertables, continuous aggregates, compression, retention, plain SQL. Self-hosted (see §12.1). |
| DB access | **Ecto + Postgrex** | Schemas, migrations; Timescale features via `execute` in migrations. |
| Background jobs | **Oban** | Follower polls, subscription management, event processing retries, rollups, retention. |
| Clustering | **libcluster** | Joins the `collector` and `web` nodes so PubSub reaches live pages. |
| Charts | **Apache ECharts** through one LiveView hook, loaded only where needed | Bands, markers, linked zoom, heatmaps, sampling in one library (§13.7). |
| Styling | **Tailwind** (Phoenix default), logical properties, dark + light themes | RTL-ready, one set of tokens for UI and charts. |
| Admin auth | **phx.gen.auth** + TOTP, no public sign-up | Admins invite admins. |
| Caching | **Cachex** in `web`; HTTP caching of `/data/v1` JSON at Caddy / Cloudflare | History never changes; serve it once. |
| i18n | **Gettext**, English first | Translation-ready (Arabic, French later). |
| Observability | **Telemetry + Phoenix LiveDashboard**, **Oban Web**, RabbitMQ management UI, admin health page | Process counts, memory, per-channel health, queue depth, job failures. |
| Hosting | **Docker Compose** on a VPS + **Caddy** for HTTPS | Each role and the receiver are separate services. |

## 10. App process design

The app is one codebase started in one of two **roles**, chosen by `ROLE`
at boot. Each role is its own service, deployed on its own.

| Role | Runs | Redeployed |
|---|---|---|
| `collector` | Poller, channel processes, chat sockets, Broadway consumer, Oban | When tracking logic changes |
| `web` | Public site, admin interface, `/data/v1` JSON | Often |

The receiver is **not** a role of the app; it is the ingress (§8.4).

```
collector
KickTracker.Supervisor (one_for_one)
├─ KickTracker.Repo
├─ Phoenix.PubSub                  (+ libcluster, shared with web)
├─ Oban                            FollowerPoll, SubscriptionSync, ProcessEvent, rollups
├─ Kick.Token                      app token (client credentials), refreshed before expiry
├─ Tracking.Registry               channel id -> its processes
├─ Tracking.ChannelsSupervisor     DynamicSupervisor
│   └─ Tracking.ChannelSup          one per channel (rest_for_one)
│       ├─ Tracking.ChannelServer   state, stream sessions, writes, broadcasts
│       └─ Tracking.ChatSocket      Pusher connection for this chatroom
├─ Tracking.Poller                 batched public API polling
├─ Events.Consumer                 Broadway pipeline on kick_tracker.events
└─ Tracking.Boot                   starts a ChannelSup per active channel on startup

web
KickTrackerWeb.Supervisor
├─ KickTracker.Repo
├─ Phoenix.PubSub                  (+ libcluster)
├─ Cachex                          query cache for aggregates
└─ KickTrackerWeb.Endpoint         public site, /admin, /data/v1; read-only against
                                   collected data, writes admin tables (§13.8)
```

**Events.Consumer** (Broadway)
- Decodes the envelope and **re-verifies the signature**. Bad or undecodable
  messages are rejected to the dead-letter queue.
- In one transaction per batch: inserts into `webhook_events`
  (`ON CONFLICT (message_id) DO NOTHING`) and, for newly inserted rows,
  writes the facts that need no channel state: `follows` and
  `support_events`.
- Then acks. Only after the commit.
- Stream status and metadata events are handed to the channel's
  `ChannelServer` after the commit. If it is down or restarting, the event
  stays unprocessed in `webhook_events` (`processed_at` null); the
  `ChannelServer` picks up unprocessed events for its channel when it starts,
  and the 5-minute poll repairs anything else.

**Poller** (one process)
- Every **60s**: `GET /livestreams` for the channels currently live, 50 per
  request, and sends each `ChannelServer` its reading: `{:reading, data, at}`.
- Every **5 min**: `GET /channels` for all tracked channels, as a safety net
  for missed live/offline and metadata events.
- If a request fails, it sends nothing. A missing reading is a gap, never
  "offline" and never zero.

**ChannelServer** (one per channel)
- Holds live/offline, the open stream, the current title and category, and
  this minute's chatters (`user_id -> messages`).
- On a status event or a poll that disagrees with its state: opens or closes
  the stream (keyed on `(channel_id, started_at)`), asks for a follower reading at
  start and end, and tells the `Poller` to include or drop it.
- On a reading: writes a viewer sample carrying the current category.
- On a metadata event or a changed title/category in a reading: writes a
  stream change.
- Every minute: flushes the minute's chat to `chat_minutes` (counts) and
  `chat_minute_users`, and upserts `chat_stream_users`, so a crash loses at
  most a minute of chat.
- On (re)start: reloads the open stream from the DB and processes its
  channel's unprocessed events, so a restart mid-stream continues the same
  stream.
- Broadcasts readings and events on `"channel:<id>"` for LiveView pages.

**ChatSocket** (one per channel)
- Connects to Pusher, subscribes to `chatrooms.<id>.v2`, answers pings.
- Sends `{:chat, sender_id, at}` and raid/host events to its `ChannelServer`.
  No message text is kept.
- Reconnects with exponential backoff (1s up to 30s) and reports connected /
  disconnected so chat coverage is recorded.
- `rest_for_one`: if the `ChannelServer` restarts, the socket restarts with
  it; if only the socket crashes, the channel's state is untouched.

**Oban jobs**
- `FollowerPoll`: v2 `followers_count`, every 15 min per live channel, daily
  per offline channel, and on demand at stream start and end. Spread out, one
  channel per job.
- `SubscriptionSync`: makes Kick's webhook subscriptions match the tracked
  channel list, pointing at the ingress URL; subscribes new channels, removes
  dropped ones, and **restores subscriptions Kick cancelled** after a long
  failure.
- `ProcessEvent`: retries status/metadata events still unprocessed after a
  while.
- Rollup refreshes, retention and compression policies.

**Adding or removing a channel** = insert or deactivate the row, start or stop
its `ChannelSup`, sync its webhook subscriptions. No redeploy.

**Growing past one collector:** Horde to spread the `ChannelSup`s across
collector nodes, the `Poller` as a cluster singleton, Broadway consumers on
every node (RabbitMQ shares the queue between them). Not needed until well
past a thousand channels.

## 11. Project layout

```
kick_tracker/
├─ app/                              # Phoenix app, roles collector + web
│  ├─ lib/
│  │  ├─ kick_tracker/
│  │  │  ├─ application.ex           # starts the tree for ROLE
│  │  │  ├─ repo.ex
│  │  │  ├─ kick/
│  │  │  │  ├─ token.ex              # app token GenServer
│  │  │  │  ├─ api.ex                # public/v1 via Req, batched, 429-aware
│  │  │  │  ├─ subscriptions.ex      # webhook subscriptions API
│  │  │  │  ├─ signature.ex          # verification (pure)
│  │  │  │  ├─ followers.ex          # v2 followers_count, isolated and replaceable
│  │  │  │  └─ pusher.ex             # frame encoding/decoding (pure)
│  │  │  ├─ events/
│  │  │  │  ├─ consumer.ex           # Broadway pipeline
│  │  │  │  ├─ envelope.ex           # decode + validate (pure)
│  │  │  │  └─ handlers.ex           # event -> facts (pure where possible)
│  │  │  ├─ tracking/
│  │  │  │  ├─ boot.ex
│  │  │  │  ├─ poller.ex
│  │  │  │  ├─ channels_supervisor.ex
│  │  │  │  ├─ channel_sup.ex
│  │  │  │  ├─ channel_server.ex
│  │  │  │  └─ chat_socket.ex
│  │  │  ├─ metrics/                 # pure functions, heavily tested:
│  │  │  │  │                        #   hours_watched, avg/peak, follower_gain,
│  │  │  │  │                        #   chat windows, gap handling
│  │  │  │  └─ sessionizer.ex        # events + readings -> stream open/close (pure)
│  │  │  ├─ channels/                # Channel schema + context
│  │  │  ├─ stats/                   # schemas + queries for the raw tables (§12)
│  │  │  └─ workers/                 # Oban jobs
│  │  └─ kick_tracker_web/
│  │     ├─ live/
│  │     │  ├─ home_live.ex             # live now, leaderboards, notable moments
│  │     │  ├─ channel_live/            # overview, streams, chat, support, categories
│  │     │  ├─ stream_live.ex           # the stream page (§13.3)
│  │     │  ├─ compare_live.ex
│  │     │  ├─ category_live.ex
│  │     │  └─ admin/                   # channels, groups, health, dead letters,
│  │     │                              #   subscriptions, reprocess, corrections,
│  │     │                              #   annotations, privacy, settings, audit
│  │     ├─ controllers/data/           # /data/v1 JSON, cacheable (§13.5)
│  │     ├─ components/                 # stat cards, period picker, chart, tables
│  │     └─ user_auth.ex                # phx.gen.auth, admin on_mount
│  ├─ assets/js/
│  │  ├─ hooks/chart.js                 # the one ECharts hook
│  │  └─ charts/                        # chart kinds: timeseries, bars, share,
│  │                                    #   heatmap, sparkline; theme tokens
│  ├─ priv/repo/migrations/          # incl. hypertables, continuous aggregates
│  ├─ test/
│  ├─ config/                        # runtime.exs: ROLE, KICK_*, DATABASE_URL, AMQP_URL
│  └─ Dockerfile                     # one image, both roles
├─ ingress/
│  ├─ receiver/                      # Elixir: Bandit + Plug + amqp + SQLite spool
│  │  └─ Dockerfile
│  └─ cloudflare/                    # later: Worker → queue
├─ sim/                              # the fake Kick (§17.2) + recorder (§17.1)
├─ fixtures/                         # recorded, anonymized Kick payloads
├─ contracts/
│  ├─ envelope.md                    # the envelope, the delivery guarantees (§8)
│  └─ envelope.schema.json
└─ deploy/
   ├─ compose.single.yml             # stage 1, one VPS
   ├─ compose.backup-receiver.yml    # stage 2, second VPS
   ├─ Caddyfile
   └─ rabbitmq/                      # definitions: exchanges, queues, users, policies
```

`contracts/` is the only thing the app and the ingress share. The
sessionizer, metrics, envelope and signature code are pure modules so the
rules that can corrupt history are tested without processes, a queue or a
database.

## 12. Data model

**Principle: store raw facts, derive everything else.** Raw tables are
written once and never changed. Every metric is a query, view, continuous
aggregate or rebuildable cache over them, so a formula can change later and
the whole history is recomputed. Nothing important exists only in derived
form.

### 12.1 Database: PostgreSQL + TimescaleDB, one database

What it has to do: mostly append-only time series (~1M viewer rows and ~5M
chat rows a day at 1 000 channels), a trickle of events, a little mutable
state (channels, open streams, processed events, Oban jobs). Reads are
per-channel time ranges, period totals, **distinct counts** and
**cross-channel comparisons**, for a handful of site users.

| | Postgres + TimescaleDB | Plain Postgres | Postgres + ClickHouse |
|---|---|---|---|
| Time series | Hypertables, ~10× compression | Partitions, no compression | Column store, 10–30× |
| Rollups | Continuous aggregates | Our own Oban jobs | Materialized views |
| Distinct counts, overlap | Fine with the chat structure below | Same | Excellent at any scale |
| Transactions, unique keys | ✅ | ✅ | ClickHouse side ❌ (eventual dedup) |
| Oban | Same database | Same database | Postgres side |
| Elixir | Ecto, mature | Ecto | Ecto + `ecto_ch` |
| Hosting | Self-hosted or Timescale's cloud | Anywhere | Two databases |

**Chosen: PostgreSQL + TimescaleDB, self-hosted.**

- With the structure below, every heavy query at our scale is small; a second
  database would cost more to run than it saves.
- The cost: compression and continuous aggregates are in the TimescaleDB
  community edition, which generic managed Postgres (RDS, Supabase…) doesn't
  offer. We self-host (or use Timescale's cloud).
- **Growth path: Postgres + ClickHouse** (the model Plausible Analytics runs
  on, in Elixir). Raw facts are append-only, so copying them to ClickHouse
  later is mechanical.

### 12.2 Identity and time

- **Kick-only.** `channels.id` is our own id; `kick_user_id` (the
  broadcaster, used by the public API and webhooks) is unique. Kick has other
  ids for the same channel (v2 channel id, chatroom id), stored as
  attributes. For one channel, e.g. channel `<channel id>` and user `<user id>` are
  different numbers.
- **Slugs change** when a streamer renames. The slug is an attribute with
  history (`channel_slugs`), never a key.
- **Streams are keyed on `(channel_id, started_at)`**, since Kick sends no
  livestream id (§3.3).
- **UTC everywhere** (`timestamptz`). Kick's time (`occurred_at`) is kept
  apart from ours (`observed_at` for polls, `received_at` for events). Events
  without their own timestamp (`channel.followed`) use the
  `Kick-Event-Message-Timestamp` header.
- **Channel timezone** (`channels.timezone`) for everything daily: rollups
  are by UTC hour and turned into days in the channel's timezone when read. A
  stream that crosses midnight counts for the day it started.

### 12.3 Chat at two levels of detail

| Table | One row per | Answers | Kept |
|---|---|---|---|
| `chat_minutes` | channel × minute | messages per minute, distinct chatters in that minute | Forever |
| `chat_minute_users` | channel × minute × chatter | active chatters for any window inside a stream | **90 days** |
| `chat_stream_users` | stream × chatter | unique chatters per stream/day/month, returning vs new, overlap between channels, top chatters | Forever |

Windows inside a stream read one stream's rows (small). Everything longer
reads `chat_stream_users`, 20–50× smaller than per-minute rows. After 90 days
a stream's per-minute detail is gone, but its per-minute counts
(`chat_minutes`) and all long-term statistics remain. No extensions needed.

### 12.4 Titles and categories

- `stream_changes` is an append-only log: field, old value, new value, when.
  It is built by comparing each `livestream.metadata.updated` snapshot with
  the previous one (the event carries every field, not only the changed
  one); `occurred_at` is the delivery's `Kick-Event-Message-Timestamp`. The
  poll's title and category fill in changes whose events were missed.
  Titles in `livestream.status.updated` are not used for changes.
- `stream_segments` is derived from it: stretches where title, category and
  language don't change. "Time per category" and "viewers after the switch
  to GTA" are simple queries on it.
- Viewer samples still carry `category_id` directly: compression makes the
  repetition nearly free and per-category queries need no join.
- `categories` is filled whenever a category is seen.

### 12.5 Tables

```
-- dimensions (normal tables, may change)
channels           (id, kick_user_id UNIQUE, kick_channel_id, chatroom_id,
                    slug, timezone, tracked_since, active)
channel_slugs      (channel_id, slug, seen_from, seen_to)
categories         (id, name, slug)
kick_users         (id, username, seen_at)
                   -- the only place usernames live; facts hold ids only

-- ingest (normal tables)
webhook_events     (message_id PK, subscription_id, type, version,
                    occurred_at, received_at, receiver, body jsonb,
                    signature, processed_at NULL)
                   -- every delivered event, permanently; source for
                   -- reprocessing if handling logic changes
coverage           (id, channel_id NULL, source: api | chat | ingress | followers,
                    from, to, ok)
                   -- our own gaps, so every stat can say how complete it is

-- streams (normal tables)
streams            (id, channel_id, started_at, ended_at NULL,
                    end_source: event | poll, kick_livestream_id NULL,
                    UNIQUE (channel_id, started_at))
stream_changes     (id, stream_id, occurred_at, field: title | category |
                    language | tags | mature, old_value, new_value)

-- time series (hypertables, compressed, segmented by channel_id)
viewer_samples     (channel_id, observed_at, stream_id, viewers, category_id,
                    PRIMARY KEY (channel_id, observed_at))
                   -- every 60s while live
follower_samples   (channel_id, observed_at, followers,
                    PRIMARY KEY (channel_id, observed_at))
                   -- 15 min live, daily offline, stream start and end
subscriber_samples (channel_id, observed_at, active, active_gifted, canceled,
                    PRIMARY KEY (channel_id, observed_at))
                   -- every 5 min, from the /channels safety-net poll
chat_minutes       (channel_id, minute, stream_id, messages, chatters,
                    PRIMARY KEY (channel_id, minute))
chat_minute_users  (channel_id, minute, user_id, messages,
                    PRIMARY KEY (channel_id, minute, user_id))
                   -- retention policy: 90 days

-- per-stream and event facts (normal tables)
chat_stream_users  (stream_id, user_id, messages, first_at, last_at,
                    PRIMARY KEY (stream_id, user_id))
follows            (message_id PK, channel_id, stream_id NULL,
                    occurred_at, user_id)
support_events     (message_id PK, channel_id, stream_id NULL, occurred_at,
                    kind: sub | resub | gift | kicks,
                    user_id NULL,            -- subscriber / gifter / sender
                    quantity,                -- giftees, months, or Kicks amount
                    tier, payload jsonb)
channel_events     (id, channel_id, stream_id NULL, occurred_at,
                    kind: raid_in | raid_out | host | ...,
                    other_channel_id NULL, viewers NULL, payload jsonb)
```

- `stream_id` is null for things that happen while offline (follows, subs,
  Kicks).
- `payload jsonb` keeps raw data so new fields need no migration.
- `follows` and `support_events` can be rebuilt from `webhook_events`.
- Unique keys on hypertables include the time column (a TimescaleDB rule).
  `webhook_events` stays a normal table: its `message_id` key is what makes
  repeated deliveries harmless.
- Writes are upserts on these keys, so replaying anything is safe.

### 12.6 Derived

- `stream_segments` (view): periods of constant title, category, language.
- `stream_stats` (cache, rebuildable): airtime, avg and peak viewers, hours
  watched, follower gain, gross follows, unique chatters, messages, subs,
  gifted subs, Kicks.
- Continuous aggregates by **UTC hour**: viewers (avg, peak, hours watched),
  chat (messages), followers (last value), support totals. Daily, weekday and
  30-day figures are built from them in the channel's timezone.

### 12.7 Retention and privacy

- Hypertables compressed after ~7 days, segmented by `channel_id`.
- `chat_minute_users`: dropped after **90 days** (TimescaleDB retention
  policy). Everything else is kept.
- Kick user ids (in the chat tables, `follows`, `support_events`,
  `webhook_events`) and usernames (`kick_users`, event bodies) count as
  personal data even without message text. Chat text is never stored.
  Usernames live in one table, so deletion requests touch one place plus the
  raw event bodies.
- Nothing from v2 beyond `followers_count` is stored.

## 13. Frontend

Two surfaces from the same `web` role: a **public site** for casual visitors
(no login, fast, shareable, honest about gaps) and an **admin interface**
(login, manages channels, watches the collection's health, repairs data).

### 13.1 Principles

- **Never ship raw data to the browser.** The server picks a resolution for
  the range and sends at most ~2 000 points per series (§13.4).
- **History is cacheable, only "now" is live.** Closed streams and past
  periods never change: they are served as cacheable JSON. Only the live part
  (current viewers, the open stream) streams over LiveView.
- **Gaps look like gaps.** Missing data breaks the line and is shaded "no
  data"; it is never drawn as zero or interpolated. Every chart and card can
  show its coverage.
- **Estimates look like estimates.** Revenue and anything modeled carry a
  label and a link to the methodology page.
- **One chart library, a few chart kinds**, used the same way everywhere.

### 13.2 Public site

| Page | Route | Content |
|---|---|---|
| Home | `/` | Live now (tracked channels on air, current viewers, sparkline), leaderboards (hours watched, avg viewers, peak, follower gain, Kicks) for 7 / 30 / 90 days / all, notable moments (records, big raids, gift bursts) |
| Channel overview | `/c/:slug` | Header (avatar, live badge, current viewers, tracked since), KPI cards with change vs previous period, viewers over the period (avg line + peak band), follower growth, weekday × hour heatmap, categories (share of hours watched), recent streams, lifetime records, coverage badge |
| Streams | `/c/:slug/streams` | Every stream: date, duration, avg / peak, hours watched, category, follower gain, chatters, support; sortable, filterable by period and category |
| Stream | `/c/:slug/streams/:id` | **The richest chart** (§13.3); live-updating while the stream is on |
| Chat | `/c/:slug/chat` | Active chatters over time, window picker (5 / 10 / 15 min, rolling), messages per minute, engagement (chatters ÷ viewers), new vs returning chatters |
| Support | `/c/:slug/support` | Subs, resubs, gifted subs, Kicks per stream and period, top gifters and supporters, estimated revenue (labeled) |
| Categories | `/c/:slug/categories` | Hours watched, airtime and avg viewers per category, viewer change after switching |
| Compare | `/compare?c=a,b,c` | 2–4 channels overlaid on the same metrics and period; chatter overlap between them |
| Category | `/category/:slug` | Tracked channels in that category, ranked |
| Methodology | `/about/methodology` | How every number is computed, what "coverage" means, what is estimated, where data comes from |

Chrome shared by all pages: period picker (7d / 30d / 90d / 1y / all /
custom) kept in the URL, channel search, and a timezone switch (see §13.6).
Every page is a URL that reproduces exactly what was shown, so links can be
shared.

### 13.3 The stream page

One time axis, stacked panels sharing zoom and crosshair:

1. **Viewers** (60s resolution), with:
   - **shaded bands** for category segments, labeled ("Just Chatting",
     "GTA V"), and ticks for title changes;
   - **markers** for raids/hosts in and out (with viewer counts), sub gift
     bursts and big Kicks;
   - "no data" shading where coverage is missing.
2. **Active chatters**, with the window picker (5 / 10 / 15 min, rolling),
   and messages per minute.
3. **Support**: subs, gifts, Kicks per minute (bars).

Beside it: stream stat cards, the change timeline (title and category
history), top chatters and supporters of the stream. While live, new points
append every 60s and the cards update.

### 13.4 Resolution by range

The server chooses the bucket from the requested range, so no series exceeds
~2 000 points:

| Range | Viewers | Chat | Source |
|---|---|---|---|
| One stream (≤ ~12h) | raw 60s samples | per minute | `viewer_samples`, `chat_minutes` |
| ≤ 7 days | 5-min buckets | 5-min buckets | `viewer_samples` (time_bucket) |
| ≤ 90 days | hourly | hourly | continuous aggregates |
| Longer | daily (channel timezone) | daily | from hourly aggregates |

Each bucket carries **avg and max** (and min where useful), drawn as a line
with a peak band, so downsampling never hides a peak. Buckets without data
are sent as `null` (a break), never 0.

### 13.5 Data delivery

- **History over cacheable JSON:** charts fetch
  `GET /data/channels/:id/viewers?from=…&to=…&res=…` and similar endpoints.
  Compact column format (`{"t":[…unix seconds…],"avg":[…],"max":[…]}`).
  Responses for closed periods get long `Cache-Control` and an ETag, so
  Caddy or Cloudflare can serve repeat visitors without touching the app.
  Ranges that include "now" get a short TTL (e.g. 30s).
- **Live over LiveView:** the page subscribes to `"channel:<id>"`; new
  readings are pushed to the chart hook with `push_event` (append a point),
  at most every 60s. Chart data is **never kept in LiveView assigns**, so a
  connected visitor costs a few KB, not a copy of the series.
- **Home page:** one aggregated `"live"` broadcast every 60s with all live
  channels' current viewers, not one per channel.
- **Query cache** (Cachex) in the `web` role for expensive aggregates
  (leaderboards, 30-day cards), keyed by query and period: minutes for
  periods including today, long for closed periods.
- The JSON endpoints are the seed of a **public read API** later; they are
  versioned from the start (`/data/v1/...`).

### 13.6 Time, numbers, languages

- **Two clocks.** Timestamps (a raid at 21:42) show in the **visitor's
  timezone** (detected in the browser, sent on connect). Daily, weekday and
  "per day" figures use the **channel's timezone**, labeled ("days in Tunis
  time"). A switch lets the visitor see everything in channel time.
- Numbers and dates formatted with the browser's `Intl` (1 086, 1,086 or
  1.086 by locale). Compact forms (26K) only in cards, exact on hover.
- **English first, translation-ready**: all text through Gettext, layout
  written with logical CSS properties (Tailwind `ms-`/`me-`, `start`/`end`)
  so an Arabic (right-to-left) or French version is a translation, not a
  redesign.

### 13.7 Charts

**Apache ECharts** for everything, loaded only on pages with charts (esbuild
code splitting). It covers every chart kind we need with one API:

- time series with shared zoom (`dataZoom`) and crosshair across panels;
- shaded bands (`markArea`) for category segments and "no data";
- event markers (`markPoint` / `markLine`) for raids, gifts, title changes;
- heatmap (weekday × hour), bars, donuts, sparklines;
- built-in `lttb` sampling and canvas rendering for dense series.

Wrapped in **one LiveView hook** and a small set of **chart kinds** written
once in JS (`timeseries`, `bars`, `share`, `heatmap`, `sparkline`). The
server sends data and a kind, never ECharts options, so every chart of a
kind looks and behaves the same and the payload stays small.

(Chart.js was the earlier pick; it lacks bands, markers, linked zoom and
heatmaps without plugins. uPlot is faster but too narrow for heatmaps and
shares.)

Also: every chart can switch to a **table view** and **export CSV** (the same
JSON), which also serves accessibility. Colors come from a colorblind-safe
palette with a dark theme by default and a light one; both from the same
tokens.

### 13.8 Admin interface

Under `/admin`, same `web` role, separate `live_session` with an `on_mount`
auth check.

- **Access:** `phx.gen.auth` accounts, **no public sign-up** (admins invite
  admins), TOTP second factor. Optionally reachable only over the private
  network (Caddy IP allowlist or Tailscale) as a second layer.
- **Channels:**
  - Add by slug: resolve through the public API, preview (avatar, ids, live
    status, category), set timezone (default from language/country, editable)
    and groups, confirm.
  - Pause / resume tracking (keeps data), deactivate (stops, keeps data),
    delete data (explicit confirmation, typed slug).
  - **Groups** (e.g. "Tunisian streamers"): lists of channels used for public
    leaderboards and the compare page.
- **Health:** per channel, live status, last poll, chat socket connected,
  webhook subscriptions per event type, last event received, last follower
  reading, coverage % for 24h and 7 days. System-wide: RabbitMQ queue depth
  and dead letters, consumer lag, receivers last seen, Oban queues and
  failures (Oban Web), LiveDashboard.
- **Dead letters:** list, inspect the envelope, replay into the queue, or
  discard with a reason.
- **Subscriptions:** Kick's webhook subscriptions vs what they should be;
  resync one channel or all.
- **Reprocess:** rebuild `stream_stats` or rollups for a channel and range;
  replay `webhook_events` through the current handlers.
- **Data corrections** (never editing raw facts, only adding on top):
  - merge two streams the sessionizer split, or split one it merged;
  - exclude a stream (test stream, rebroadcast) from statistics;
  - **annotations** on a channel's timeline ("collector outage", "suspected
    viewbots", "charity stream"), optionally shown publicly on charts.
- **Privacy:** find everything held about a Kick user id; delete it
  (per-user rows, username, raw event bodies redacted).
- **Settings:** polling cadences, feature flags (e.g. show the support page
  publicly), public groups.
- **Audit log:** every admin action, who and when.

**How admin actions reach the collector:** the database is the source of
truth. The admin writes (e.g. a new active channel) and broadcasts
`"channels:changed"` over the cluster; the collector reconciles (start or
stop `ChannelSup`s, sync subscriptions). The collector also reconciles from
the database every minute, so a lost message only delays the change.

New tables for this: `admins` (phx.gen.auth), `channel_groups`,
`channel_group_members`, `stream_overrides` (merge / split / exclude),
`annotations`, `admin_audit_log`, `settings`. The `web` role is read-only
against the collected data and writes only these.

### 13.9 Performance targets

- Public page first render < 1s on a phone; chart data < 100 KB per chart.
- Server-rendered first paint (LiveView's static render) with titles and meta
  tags, so pages are indexable and links preview properly.
- Open Graph images per channel and stream (later): a server-rendered SVG
  summary card converted to PNG, so shared links show the channel's numbers.
- A visitor on a live page costs one LiveView process with no chart data in
  it; thousands of concurrent visitors fit on the same server.

## 14. Collection rules

- **Gaps are recorded as gaps.** A failed poll writes nothing, never a zero.
  No answer is not the same as offline. Every gap lands in `coverage`.
- **Hours watched** = Σ `viewers × min(Δt, 75s)`: 75s tolerates a poll a
  few seconds late, while a missed poll (a 120s gap) is filled by at most
  15s, never interpolated.
- **Events are idempotent** (unique `message_id`) and **order-independent**
  (event timestamps and `started_at`, never arrival order).
- **UTC everywhere, channel timezone at read time**: daily and weekday
  figures are built from UTC hours in the channel's timezone; a stream that
  crosses midnight counts for the day it started.
- **Ack after commit**; the receiver answers Kick only after a publisher
  confirm or a spool write.
- **Webhooks lead, polling corrects**: stream state and metadata from events,
  the 5-minute poll repairs anything missed.
- **Metric, sessionizing, envelope and signature code is pure** and tested;
  it is where bugs silently corrupt history.
- **Batch and back off**: 50 channels per public API request, respect 429;
  v2 requests spread out, one channel at a time.
- **Chat and v2 are optional**: if Pusher or v2 fails, everything else keeps
  collecting.
- **Estimates are labeled** (revenue, anything modeled).

## 15. Deployment and redundancy

### 15.1 Services

| Service | Image | Redeployed | Down means |
|---|---|---|---|
| `receiver` ×2 | `ingress/receiver` | Rarely, one at a time | Nothing, while the other answers |
| `rabbitmq` | official | Rarely | Receivers spool to disk; nothing lost |
| `collector` | `app`, `ROLE=collector` | When tracking changes | Events wait in the queue; at most one missed 60s reading and seconds of chat, recorded in `coverage` |
| `web` | `app`, `ROLE=web` | Often | Site down; collection unaffected |
| `db` | TimescaleDB | Rarely | Consumer stops acking, events wait in the queue; polling pauses |
| `caddy` | official | Rarely | Ingress unreachable (see stage 2) |

`docker compose up -d web` redeploys only the website; the receivers and the
queue keep running the images they have.

### 15.2 Stages

**Stage 1: one VPS.**
Caddy → two receivers (`lb_policy first`, active health checks) → RabbitMQ
(single node) → collector. Covers receiver crashes and receiver updates;
app deploys never touch webhook intake.

**Stage 2: backup receiver on a second VPS.**
Same receiver image on another provider or region, with its own spool,
publishing to RabbitMQ over a private network (WireGuard or Tailscale). The
webhook hostname is routed by **Cloudflare Load Balancing** (health-checked
failover between the two machines). Covers the main VPS or Caddy going down:
events are received and spooled on the backup until RabbitMQ is back.

**Stage 3 (if ever needed): a redundant queue.**
A 3-node RabbitMQ cluster (quorum queues replicate across nodes), or managed
RabbitMQ (CloudAMQP), or another queue with its own Broadway producer. No
change to the app beyond producer config.

### 15.3 Deploy rules

- Migrations are **expand-then-contract**: add first, remove only once no
  running code uses it. `collector` and `web` may run different versions for a
  while.
- The receiver never touches the database, so app migrations never affect it.
- The envelope changes only in a backward-compatible way (new optional
  fields); a breaking change means a new `version` and a consumer that reads
  both.
- Redeploy receivers one at a time; the other keeps answering.

## 16. Open questions

Answered:

- ~~Is follower count in the public API?~~ No. Totals from v2 (§2.3), gross
  follows from `channel.followed`.
- ~~Batching limits?~~ 50 channels per request for `livestreams` and
  `channels`.
- ~~Is there a "stream started" signal?~~ Yes, `livestream.status.updated`,
  subscribable with the app token; the same event signals the end.
- ~~How often does Kick refresh `viewer_count`?~~ About every 60s (§2.1).
- ~~Are the `channels` subscriber-count fields filled for channels that
  haven't authorized us?~~ Yes (§2.1); now tracked every 5 minutes.
- ~~Does Pusher accept connections without auth?~~ Yes, from a home machine
  (§2.4).

Partly answered:

- **Sub, gift and Kicks webhooks with the app token:** subscriptions are
  accepted for a channel that hasn't authorized us; no delivery of those
  types observed yet. Seven of the ten event types are still uncaptured:
  `channel.subscription.new`, `.renewal`, `.gifts`, `kicks.gifted`,
  `moderation.banned`, `channel.reward.redemption.updated` and
  `chat.message.sent`. Record a busy channel where people subscribe, gift
  and get timed out. Until then the simulator's shapes for them follow the
  documentation, and must be re-checked against a recording.
- **Public API rate limits:** no rate-limit headers are sent, so the limits
  are unknown. We don't probe for them; stay batched and back off on 429.

Still open:

1. **Kick's webhook retry policy:** stop the ingress, trigger an event, watch
   whether and when it is delivered again. Decides how urgent stages 2 and 3
   are.
2. **Does v2 answer from the VPS** (datacenter IP), not just from home?
   And `api.kick.com/private/v1/channels/{slug}` (§2.3b): if v2 is blocked
   from a datacenter and this isn't, it becomes the follower source. Run
   `mix record.probe` and `mix record.v2` from the VPS.
3. **Pusher from a datacenter IP**, any limit on subscriptions per
   connection, and the exact raid/host event names.
4. **Outgoing raids:** visible from the raiding channel's feed, or only in the
   target's?

## 17. Development: recorded payloads and a fake Kick

Two things come **before** any tracking logic: real payloads recorded once,
and a fake Kick built from them. Together they let us develop the pipeline
and the website without hammering Kick's endpoints, and generate as much
data as we want, whenever we want, including the failures that are rare in
real life.

### 17.1 Recording real payloads (once, lightly)

A set of `mix` tasks in `sim/` (`record.api`, `record.v2`, `record.pusher`,
`record.subscribe`, `record.webhooks`, `record.probe`, then
`fixtures.anonymize`), run by hand
against the real Kick, on one or two channels, for a limited time. The
runbook is `sim/README.md`. They record:

- **Public API:** `/livestreams`, `/channels`, the token endpoint, and error
  responses (401, 404, 429 if seen).
- **v2:** one `channels/<slug>` response per recorded channel.
- **Webhooks:** subscribe the recorded channels through a tunnel and keep
  every delivery **with its headers** (for signature tests), all event
  types we can trigger or wait for.
- **Pusher:** raw frames from a chatroom: connection, subscription, pings,
  chat messages, and raids / hosts / anything else that shows up.

Raw recordings go to `sim/recordings/` (git-ignored); tokens, `Authorization`
and v2's `playback_url` are redacted before anything is written. They reach
`fixtures/` only through `mix fixtures.anonymize`: user and channel ids,
usernames and slugs, avatars and every URL, and free text (chat, titles,
bios) are replaced consistently, so the same person stays the same fake
person across files and runs (the mapping stays in `sim/recordings/`). It
reports every text field it kept without a rule, by path only, for review
before committing, and then runs an independent **leak check**: every real
username, slug, chat text and id in the raw files is searched for in the
output (names, chat texts, numeric and string ids, UUIDs), and the run fails
if any is found. (On the first real data it caught the channel id under
`chatroom.chatable_id`, which the rules had missed.) UUIDs and opaque string
ids are replaced by consistent fakes of the same shape, so links between
messages survive; the ids Kick issues to our app for webhook subscriptions
and deliveries are kept, since they also appear in webhook headers. Signed webhook fixtures keep their original
body next to the anonymized one, since re-signing is impossible without
Kick's key; signature tests use the originals, and those files stay out of
the public repo if it ever becomes public.

The same run answers most open questions (§16): retry behavior, refresh
rate of `viewer_count`, rate limits, v2 from the VPS, app-token access to
sub / Kicks events.

The recorder is re-run when Kick changes something (a new event version, a
changed field), and fixtures are versioned with the event version.

### 17.2 The fake Kick (`sim/`)

A standalone Elixir app (Bandit + Plug + WebSock) that **speaks Kick's
protocols**, built from the fixtures:

| Real | Fake |
|---|---|
| `id.kick.com` token endpoint | Issues tokens, expiring, refreshable |
| `api.kick.com/public/v1` | `/livestreams`, `/channels`, `/events/subscriptions`, with the 50-per-request limit and 429s |
| `kick.com/api/v2/channels/<slug>` | `followers_count` and the rest of the shape |
| Pusher websocket | The subset of the Pusher protocol we use: connect, subscribe, ping/pong, chat, raids, hosts |
| Webhook deliveries | POSTs to the ingress URL with all `Kick-Event-*` headers, **signed with the simulator's own key pair** |

The app and ingress point at it purely **through configuration**
(`KICK_API_URL`, `KICK_ID_URL`, `KICK_V2_URL`, `PUSHER_URL`,
`KICK_PUBLIC_KEY`). No code path knows it is talking to a fake; if something
only works against the simulator, that is a bug.

**Scenarios** (plain Elixir or YAML, seeded, reproducible):

- **Channels with profiles:** size (50 to 50 000 viewers), schedule (days,
  start times, durations), viewer curve shape (ramp-up, plateau, decline),
  chat rate and chatter pool, category switches and title changes, follower
  growth, sub / gift / Kicks rates, raids between channels.
- **Fault injection**, switchable per scenario: dropped, duplicated,
  delayed and out-of-order webhooks; webhook retries; 429s, 5xx and timeouts;
  Pusher disconnects; viewer glitches (a sudden 0, a one-reading spike);
  brief stream drops with the same or a new `started_at`; streams crossing
  midnight or lasting over 24h; renamed slugs; banned channels.
- **Controls:** a small HTTP API and CLI to trigger things on demand ("start
  stream on channel X", "raid X → Y with 1 200", "gift 50 subs", "drop the
  socket"), for manual testing and demos.

**Built so far** (2026-09-24): the clock, scenarios and channel profiles,
schedules and viewer curves, the payload builders, the HTTP side (token,
public key, channels, livestreams, webhook subscriptions, v2), signed
webhook delivery with drop and duplicate faults, and a process per channel
that announces streams starting and ending, title and category changes, and
the follows, subs, gifts, Kicks, bans and redemptions of each passing
minute, and a Pusher websocket carrying each stream's chat (with the
handshake, pings, and the disconnect codes real Pusher uses). The recorder
drives all of it unchanged, and its payload shapes (API, webhooks, chat
frames) are checked against `fixtures/` by tests, so a shape Kick changes
shows up when we re-record. Raids and hosts wait for a recording (their
event names are unknown). A control API (`/_sim`) and CLI (`mix sim.ctl`)
drive it by hand: start or end a stream now, change title or category,
send any event, move or speed up the clock, drop the next N webhooks, set
faults, disconnect Pusher clients, expire tokens. Manual changes are
overrides layered over the schedule, so the simulation stays a function of
time. Still to come: bulk mode (phase 2).

**Two modes:**

1. **Live mode:** the simulator runs in real time (or a faster clock for
   the simulator only) and the whole pipeline runs against it: ingress →
   RabbitMQ → collector → database → site. Used to develop and test the
   pipeline end to end.
2. **Bulk mode** (after phase 2, see below): generates **months of history** for dozens or hundreds of
   channels in minutes, written straight into the raw fact tables with the
   same shapes the pipeline would produce. Used to develop the website,
   charts, rollups and performance at realistic volume (§6), without waiting
   for real time to pass. Bulk data is tagged so it can never mix with real
   data (separate database in practice).

The simulator is also what the automated end-to-end tests run against.

### 17.3 Tests alongside features

Tests are written **with** each feature or logic change, not in a later
phase:

- Pure modules (sessionizer, metrics, envelope, signature, parsers) get unit
  tests, and **property tests** (StreamData) for anything that must survive
  random orders, duplicates and gaps.
- Parsers are tested against the recorded fixtures.
- Pipeline pieces get integration tests against the simulator, with real
  TimescaleDB and RabbitMQ in containers.
- A change to a metric or the sessionizer comes with a test showing the
  before and after.

## 18. Operations and legal

Done once the core logic and features work (§20, phase 5), **before real
data collection starts in earnest**.

### 18.1 Backups

The collected history can't be fetched again from Kick; losing the database
loses it for good.

- Continuous Postgres backups with point-in-time recovery (**WAL-G** or
  **pgBackRest**) to object storage off the VPS (Backblaze B2, Cloudflare R2
  or S3).
- **Restore tested regularly**, scripted, into a scratch database, with a
  check that row counts and a few metrics match.
- Also backed up: RabbitMQ definitions, `deploy/` config, encrypted secrets.
  Receiver spools are short-lived and not backed up.

### 18.2 Alerts

Notifications (Telegram, Discord or email), not just dashboards, when:

- a channel is live but no viewer readings arrive;
- no webhooks arrive while channels are live;
- the dead-letter queue grows, or the consumer falls behind;
- a chat socket stays disconnected;
- coverage for a channel drops below a threshold;
- disk nearly full, a backup fails, a certificate is close to expiry.

Plus an **external uptime check** on the ingress URL and the site, and error
tracking (**ErrorTracker**, self-hosted in Elixir, or Sentry).

### 18.3 Legal and privacy

- **Kick's developer terms:** read for rules on storing and displaying data,
  attribution and rate limits. v2 and Pusher are the grey area; both can
  already be switched off.
- **Public name without "Kick"** in it or its logo (trademark). The repo name
  doesn't matter.
- **Privacy:** GDPR (EU visitors, EU chatters whose ids we store) and
  Tunisia's data protection law. A privacy policy, a stated legal basis
  (legitimate interest), deletion requests (admin, §13.8), and a way for a
  **streamer to ask to be removed**.
- A User-Agent identifying us, with a contact address, on every request to
  Kick.

## 19. Hardening

Done after everything else is set up and working (§20, phase 6).

### 19.1 CI/CD

- On every push: `mix format --check-formatted`, Credo, Dialyzer, tests
  (with TimescaleDB, RabbitMQ and the simulator as services).
- Images built and pushed to GHCR, one per deployable (app, receiver).
- **Deploy per role**, migrations as a separate step before a deploy,
  following the expand-then-contract rule (§15.3).

### 19.2 Data quality

- Outlier detection on viewer readings (a sudden 0 mid-stream, a one-reading
  spike): **flagged, never deleted**, and excluded from peaks when flagged.
- Strict parsing, with an **alert when a payload changes shape** (missing
  field, unknown event version); new versions handled side by side.
- Server clocks synced (NTP); a check that event times and our times don't
  drift apart.
- Edge cases from §17.2's fault list covered by tests and handled in the
  sessionizer.

### 19.3 Security

- Rate limits on public pages and `/data` (Hammer or PlugAttack).
- Security headers (CSP, HSTS, frame options).
- **Sobelow** (static security analysis) and **mix_audit** (vulnerable
  dependencies) in CI.
- Secrets encrypted in the repo (sops + age), never committed in clear.
- Admin behind the private network in production, TOTP enforced.

## 20. Next steps

Tests are written alongside every step (§17.3), not as a step of their own.

**Phase 0: set up and record**

1. Register a Kick app, get client id and secret.
2. `contracts/envelope.md` + schema.
3. The recorder (§17.1): record API, v2, webhooks (through a tunnel) and
   Pusher for one or two channels; anonymize into `fixtures/`. Answer
   the open questions (§16) along the way.

**Phase 1: the fake Kick**

4. `sim/`: token endpoint, public API, v2, Pusher, signed webhook sender,
   built from the fixtures.
5. Scenarios with channel profiles and fault injection; control API and CLI.
6. Control API and CLI.

   (Bulk mode moves to phase 2: it writes the raw fact tables, which don't
   exist until the schema does. Everything it needs is already pure and
   time-addressable, so it is a writer over `Schedule.windows_between/3`
   and `Curve`, not new simulation.)

**Phase 2: the pipeline, against the simulator**

7. `mix phx.new` in `app/`, Docker Compose (TimescaleDB, RabbitMQ,
   simulator), first migrations (channels, webhook_events, streams,
   viewer_samples as a hypertable, coverage), `ROLE` switch; every Kick URL
   and key from configuration.
8. `ingress/receiver`: signature verification, publisher confirms, SQLite
   spool; `deploy/rabbitmq` definitions.
9. `Events.Consumer` (Broadway) writing `webhook_events`.
10. `Kick.Token`, `Kick.API`, `Poller` and `ChannelServer` writing viewer
    samples; stream start/end and metadata from events; `Sessionizer`;
    `SubscriptionSync`.
11. `FollowerPoll` (v2), `follows`, support events.
12. `ChatSocket`, the three chat tables, raids and hosts.
13. `Metrics`; `stream_stats`; continuous aggregates.
13b. Bulk mode: months of history written straight into the raw tables.

**Phase 3: admin core**

14. Auth, add / pause channels, health page.

**Phase 4: the public site (on bulk-mode data, then live-mode data)**

15. `/data/v1` endpoints with resolution by range; the ECharts hook and chart
    kinds.
16. Stream page (the richest chart), then channel overview.
17. Home, leaderboards, compare, category pages; caching.
18. Rest of admin: dead letters, reprocess, corrections, annotations,
    privacy, audit log.

**Phase 5: operations and legal (§18), then real collection**

19. Backups with a tested restore.
20. Alerts, uptime checks, error tracking.
21. Kick terms reviewed, public name, privacy policy, removal requests.
22. Point the configuration at the real Kick; start tracking the first real
    channels.

**Phase 6: hardening (§19)**

23. CI/CD.
24. Data quality checks.
25. Security.

**Later** (not planned yet): history before tracking from v2's VOD list
(marked as imported), streamer accounts via Kick login with private stats and
embeds, Discord notifications, a public read API, Open Graph images.
