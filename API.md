# Read API (`/api/v1`)

Read-only access to the figures this site collects about Kick channels, for other
applications. Keys are issued by hand by the site's admins; each key reaches the
channels and kinds of data chosen for it. Send this file with the key.

The format below is a contract: `v1` only gains fields. A change that would break a
client becomes `v2`.

## Authentication

Send the key in a header on every request:

```
Authorization: Bearer kt_...
```

A key in the URL is ignored (URLs end up in logs). Without a valid key, or from an
address the key isn't allowed from, the answer is `401` `invalid_key`. A revoked or
edited key takes effect within 30 seconds.

## Errors

```json
{"error": {"code": "out_of_scope", "message": "This key can't read \"chat\" for this channel."}}
```

| Status | `code` | Meaning |
|---|---|---|
| 401 | `invalid_key` | No key, an unknown, revoked or expired one, or one not allowed from this address |
| 403 | `out_of_scope` | The key reaches the channel, but not this kind of data |
| 403 | `resolution` | Per-minute figures for a key held to a coarser resolution |
| 404 | `not_found` | No such channel or stream, **or one this key doesn't reach** (the two look the same) |
| 429 | — | Over the key's rate limit; `Retry-After` says when to try again |

Match on `code`; messages may change.

## Rate limits

Each key has its own limit per minute (600 unless the admin set another), counted per
key whatever the address. Requests without a valid key: 60 a minute per address.
The site runs on two servers that count separately, so a client spreading its
requests over several addresses may see up to twice its limit; don't rely on it.

## What a key reaches

**Channels.** A key reaches every channel, or only chosen channels and groups of
channels. Each channel the key reaches has an **access**:

- `full`: everything the key's scopes allow.
- `live`: only "now" (`/now`, `/live`), for a channel the site shows only while it is
  live. No history.

Channels hidden from the site are not reached (except by admin keys).

**Scopes** (the kinds of data):

| Scope | Gives |
|---|---|
| `channels` | The list of channels, a channel's streams, a stream's timeline |
| `live` | Who is live now: current viewers and active chatters |
| `viewers` | Viewers over time, the weekday × hour heatmap, viewer figures of streams |
| `chat` | Messages and chatters over time, active chatters in a stream, chat figures of streams |
| `followers` | Follower totals over time, follower figures of streams |
| `support` | Subs, resubs, gifted subs and Kicks over time and per stream |
| `categories` | Hours watched, airtime and viewers per category |

**Limits** a key may have: how far back it reads (older ranges are cut, and the answer
says `"clamped": true`), the finest resolution it gets, the addresses it works from,
and an end date.

**Admin keys** reach every channel, including hidden ones, and every kind of data,
including the logged chat of channels where chat logging is on.

## Conventions

- **`null` means unknown, never zero.** A figure we didn't record (no reading, a gap in
  collection, a webhook outage) is `null`. A `0` is a zero we recorded. Never turn
  `null` into `0` when summing or charting.
- **Gaps** are listed in `gaps` as `[from, to]` pairs of unix seconds: stretches where
  we weren't collecting. Draw them as breaks, not as lines across.
- **Times:** points in series and timelines are unix seconds (UTC). Timestamps on
  records (a channel, a stream, a chat message) are ISO 8601 in UTC.
- **Ranges** are `[from, to)`. Give `period` (`24h`, `7d`, `30d`, `90d`, `1y`, `all`;
  default `30d`) or `from` and `to` (unix seconds or ISO 8601, at most 20 years apart).
  Every range answer repeats `from`, `to` (unix seconds) and `clamped`.
- **Resolution:** the server picks the bucket from the range so a series never has
  more than 2 000 points: raw 60-second readings up to 12 hours, then 5 minutes (up
  to 6 days), 15 minutes (20 days), 1 hour (80 days), 6 hours (200 days), 1 day, 1 week.
  Days and weeks follow the channel's timezone. `res` (`raw`, `5m`, `15m`, `1h`, `6h`,
  `1d`, `1w`) can only ask for fewer points. The answer's `res` says what was used.
- **Buckets** carry the average and the maximum (`avg`, `max`), so downsampling never
  hides a peak. An empty bucket is `null`.
- **Viewers** are polled every 60 seconds. **Hours watched** = Σ viewers × time
  between readings, each interval capped at 75 seconds.
- Answers carry an `ETag`; send `If-None-Match` to get a `304` when nothing changed.

## Endpoints

All `GET`, under `/api/v1`. `:slug` is a channel's Kick slug (an old slug still finds
a renamed channel).

### `/channels`

The channels the key reaches (scope `channels` or `live`).

```json
{"channels": [
  {"slug": "somestreamer", "access": "full", "live": true,
   "scopes": ["channels", "live", "viewers"],
   "kick_user_id": 1234567, "timezone": "Africa/Tunis",
   "tracked_since": "2026-03-01T00:00:00.000000Z", "tracking": true},
  {"slug": "otherstreamer", "access": "live", "live": false, "scopes": ["live"]}
]}
```

`scopes` lists what this key may read of that channel. Admin keys also get
`visibility` (`public`, `live_only`, `hidden`).

### `/channels/:slug`

One channel, as in the list.

### `/live` and `/channels/:slug/now`

Who is live now (scope `live`), all channels or one:

```json
{"slug": "somestreamer", "live": true, "viewers": 1234,
 "observed_at": "2026-09-28T12:00:05Z", "active_chatters": 87,
 "stream_id": 42, "started_at": "2026-09-28T10:00:00Z",
 "title": "…", "category": "Just Chatting"}
```

`viewers` is `null` when the latest reading is older than 5 minutes. `active_chatters`
counts distinct people who chatted in the last 5 whole minutes; `null` unless we were
listening to the chat all that time. A channel with `live` access has no `stream_id`,
`started_at`, `title` or `category`. Offline: `{"slug": …, "live": false}`.

### `/channels/:slug/streams?period=…&limit=…`

The channel's streams that started in the range, newest first (scope `channels`;
`limit` 1–500, default 100):

```json
{"from": 1756000000, "to": 1758600000, "clamped": false, "streams": [
  {"id": 42, "started_at": "…", "ended_at": null, "airtime_s": 7200,
   "category": "Just Chatting", "excluded": false,
   "avg_viewers": 1100.5, "peak_viewers": 1500, "hours_watched": 2201.0,
   "unique_chatters": 310, "messages": 5400,
   "follower_gain": 120, "follows": 130,
   "subs": 12, "resubs": 30, "gifted_subs": 50, "kicks": 2000}
]}
```

Figures appear only for the scopes the key has (`viewers`: avg, peak, hours watched;
`chat`: unique chatters, messages; `followers`: follower gain, follows; `support`:
subs, resubs, gifted subs, Kicks). `ended_at` is `null` while live. `excluded` marks a
stream an admin left out of the channel's figures (a restream, a test).

### `/channels/:slug/viewers` (scope `viewers`)

```json
{"res": "15m", "tz": "Africa/Tunis", "from": …, "to": …, "clamped": false,
 "t": [1758000000, 1758000900], "avg": [1100.2, null], "max": [1200, null],
 "gaps": [[1758000900, 1758003600]]}
```

### `/channels/:slug/chat` (scope `chat`)

Columns `messages` (per bucket) and `chatters`: the most distinct chatters in any one
minute of the bucket (per minute at `raw`), given only up to 15-minute buckets (for
coarser ones `chatters` is `null` as a whole). A bucket's values are `null` where we
weren't receiving the chat.

### `/channels/:slug/followers` (scope `followers`)

Follower totals: `v` (the last reading in the bucket), `min`, `max`. Buckets without
a reading are left out (a total between two readings lies between them).

### `/channels/:slug/support` (scope `support`)

Columns `subs`, `gifts`, `kicks` per bucket; `null` where we weren't receiving Kick's
events.

### `/channels/:slug/heatmap` (scope `viewers`)

Average viewers by weekday (7 rows, Monday first) and hour of day (24 columns, from
midnight), in the channel's timezone, rounded: `{"timezone", "days", "values"}`. A cell
with no readings is `null`. In a timezone not a whole number of hours from UTC, days and
hours are counted in whole UTC hours, so they can be off by up to 45 minutes.

### `/channels/:slug/categories` (scope `categories`)

```json
{"categories": [{"name": "Just Chatting", "hours_watched": 1200.5, "share": 0.61,
  "airtime_s": 36000, "avg_viewers": 900.1, "switch_change": 0.05, "switches": 3}]}
```

### `/streams/:id` (scope `channels`)

One stream: `stream` (`id`, `channel`, `started_at`, `ended_at`, `live`), its
`segments` (categories over time), `titles`, `markers` (raids, hosts; gift bursts and
big Kicks with scope `support`), public `annotations`, and the series the key's scopes
include: `viewers`, `chat`, `support`, at the finest resolution the stream's length
allows.

### `/streams/:id/chatters?window=5` (scope `chat`)

Active chatters in a rolling window (1, 5, 10, 15 or 30 minutes), one point a minute:
`{"window", "t", "chatters"}`. `null` where we weren't listening, or where the window
reaches before the 90 days per-minute detail is kept.

### `/channels/:slug/chat-log/messages` and `/chat-log/events` (admin keys)

A channel's logged chat, newest first, a page at a time: the last 24 hours unless a
`period` or `from`/`to` is given; `limit` 1–1000 (default 200); `before` is the `next`
of the previous page (`null` on the last one).

```json
{"channel": "somestreamer", "from": …, "to": …, "clamped": false, "next": "…",
 "messages": [{"sent_at": "…", "message_id": "…", "user_id": 1234567,
   "username": "…", "type": "message", "content": "…",
   "reply_to": null}]}
```

Events (`occurred_at`, `event`, `payload`) are the chat feed's other events (bans,
deleted messages, pins…) as Kick sent them. Only channels with chat logging on have a
log, kept for that channel's retention; people who asked for their data to be deleted
are gone from it.
