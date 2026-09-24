# sim

The fake Kick (phase 1, not built yet) and the **recorder** (phase 0): small
tasks, run by hand, that record what the real Kick sends so the simulator and
the parser tests can be built from real payloads (`project.md` §17).

The recorder is the **only** code allowed to call the real Kick before
phase 5 (`AGENTS.md` §6). Keep runs short and on one or two channels.

## The fake Kick

```bash
mix sim
```

Serves, on one port, what the real Kick spreads over three hosts: the token
endpoint, `/public/v1/*` (channels, livestreams, public key, webhook
subscriptions), `/api/v2/channels/{slug}`, and webhook delivery signed with
its own key. Point the code under test at it:

```
KICK_API_URL=http://127.0.0.1:4050
KICK_ID_URL=http://127.0.0.1:4050
KICK_V2_URL=http://127.0.0.1:4050/api/v2
PUSHER_URL=ws://127.0.0.1:4050/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false
```

Useful options:

```bash
mix sim --port 4050 --scenario scenarios/busy.exs --webhook-url http://localhost:4040/
mix sim --from 2026-01-01T00:00:00Z --speed 60    # a simulated hour a minute
```

What it simulates: channels with a size and a weekly schedule, viewer
curves that ramp up, plateau and decline, title and category changes
partway through a stream, follower growth, and chat volume with a pool of
chatters who come back. **Viewer counts change once a minute**, like Kick's
own, so polling faster sees repeats, exactly as in the real thing.

Everything is a function of simulated time and the channel's seed, so the
same moment always gives the same answer: the simulator can be restarted,
asked about the past, or run fast without keeping any history.

A scenario file is an `.exs` script ending in a keyword list:

```elixir
[
  seed: 7,
  channels: [
    [slug: "bigstreamer", peak_viewers: 20_000,
     schedule: %{days: [1, 2, 3, 4, 5], start_hour: 19, duration_min: 300}],
    [slug: "smallstreamer", peak_viewers: 40, schedule: :always],
    [slug: "quietstreamer", schedule: :never]
  ],
  faults: [drop_webhooks: 0.05, duplicate_webhooks: 0.02]
]
```

Without `--scenario` it runs `Sim.Scenarios.default/0`: a big weekday
channel, a mid-sized daily one, a small weekend one, and one that never
goes live.

Each channel also runs a process that announces what happens: a stream
going live (`livestream.status.updated`, then
`livestream.metadata.updated`, in Kick's own order), title and category
changes partway through, the stream ending with the time it really ended,
and minute by minute the follows, subs, resubs, gift bursts, Kicks, bans
and channel-point redemptions its audience produced. That is all ten event
types Kick documents, chat included (`chat.message.sent` goes to an app
that subscribed to it).

**Pusher** runs on the same port (`/app/<key>`). It speaks what Kick's chat
uses: `pusher:connection_established` on connect, `pusher:subscribe` with
an empty `auth`, pings both ways, and `App\Events\ChatMessageEvent`
frames for each subscribed `chatrooms.<id>.v2`, their `data` a JSON string
as Pusher sends it. Chat follows the audience: more viewers, more messages,
from a pool of chatters who come back, about one in twenty a reply to an
earlier message. It also does what real Pusher does to misbehaving
clients: a wrong app key gets `pusher:error` 4001, and a client that
misses a pong is dropped with 4201. The `pusher_disconnect_after_s` fault
closes every socket with 4200 after that long, to test reconnecting.

Three of those ten have been captured from the real Kick; the rest follow
Kick's documented field lists and must be re-checked once recorded
(project.md §16).

Raids and hosts aren't simulated yet: none has been recorded, so their
Pusher event names are unknown (project.md §16).

### Driving it by hand: `mix sim.ctl`

With `mix sim` running, another terminal drives it:

```bash
mix sim.ctl status
mix sim.ctl live <channel> --minutes 90      # start a stream now
mix sim.ctl offline <channel>                # end it now (scheduled or not)
mix sim.ctl title <channel> "New title"
mix sim.ctl category <channel> 15
mix sim.ctl event <channel> gift --count 20 --anonymous
mix sim.ctl chat <channel> "hello chat"
mix sim.ctl clock --advance 2h               # or --at <ISO time>, --speed 60
mix sim.ctl webhooks http://localhost:4040/  # where to deliver
mix sim.ctl webhooks --drop-next 3           # lose the next three on purpose
mix sim.ctl faults --drop 0.1 --pusher-disconnect 30
mix sim.ctl disconnect                       # close every Pusher socket
mix sim.ctl expire-tokens                    # force the app to re-authenticate
```

`mix help sim.ctl` lists every option. It's a thin client over the control
API at `/_sim` (documented in `Sim.Http.Control`), which tests can call
directly.

Manual changes are **overrides layered over the schedule**, stored with the
channel: a stream started by hand is a window like any other, and a
scheduled one ended early has its real end recorded. So the simulation
stays a function of time, and the stream-end event reports when the stream
actually ended.

**Not built yet:** bulk history (phase 2, once the database exists).

## Setup

```bash
cd sim
mix deps.get
cp .env.example .env    # then fill in KICK_CLIENT_ID and KICK_CLIENT_SECRET
```

`.env` is git-ignored. Variables already set in your shell take precedence.

## What gets written where

| Where | What | In git? |
|---|---|---|
| `sim/recordings/<time>-<task>/` | Raw recordings: real data, exact bodies, real signatures. Tokens, `Authorization` and v2's `playback_url` are redacted before writing. | **No** (ignored) |
| `sim/recordings/.anonymizer-map.json` | Real → fake mapping, so pseudonyms stay stable across runs. Contains real values. | **No** (ignored) |
| `fixtures/` | Anonymized copies, made by `mix fixtures.anonymize`. | Yes, after review |

## Recording session

Pick one or two channels that are **live and chatty** while you record.

### 1. Public API and the viewer refresh rate

```bash
mix record.api --slugs <channel> --minutes 10 --interval 15
```

Records the token response, the webhook public key, `/channels`,
`/livestreams` every 15s, and two error shapes. `summary.json` answers how
often `viewer_count` actually changes and lists any rate-limit headers.

### 2. v2 follower count

```bash
mix record.v2 --slugs <channel>
```

Run it at home **and on the VPS**: whether v2 answers from a datacenter IP is
an open question (§16).

### 3. Pusher chat feed

```bash
mix record.pusher --slug <channel> --minutes 20
```

Records every frame from the chatroom and the channel feed, to learn the
exact event names for chat, raids, hosts, subs.

### 4. Undocumented website endpoints

```bash
mix record.probe --slug <channel>
```

Requests each candidate endpoint from Kick's undocumented website API once
(one per second), for one live channel: follower and viewer counts on
`api.kick.com`, leaderboards, videos, clips and more (the list is in
`Sim.Recorder.Probe`). An `api.kick.com` endpoint answering 401/403 is tried
once more with our app token. `summary.json` shows per endpoint the status,
whether it was JSON or a Cloudflare page, top-level keys, and count-like
fields (names only). Run it **from the VPS too**: if the `api.kick.com`
follower count answers from a datacenter, it can replace v2.

### 5. Webhooks (needs a tunnel)

Kick sends webhooks to the URL in **your app's settings on kick.com**.

```bash
cloudflared tunnel --url http://localhost:4040   # prints a https://….trycloudflare.com URL
```

1. Put that URL in the Kick app's webhook setting (and enable webhooks).
2. Subscribe the channel:

   ```bash
   mix record.subscribe --slugs <channel>
   ```

   Its output shows, per event, whether Kick accepted it with our app token,
   which answers whether sub, gift and Kicks events work for a channel that
   hasn't authorized us (§16).
3. Capture for an hour (going live/offline, a title change or a follow will
   produce events):

   ```bash
   mix record.webhooks --minutes 60
   ```

4. **Retry test** (§16, the most important open question): answer 500 to
   everything for 10 minutes, then accept, and see if and when Kick
   redelivers:

   ```bash
   mix record.webhooks --minutes 60 --fail-for 600
   ```

   `summary.json` lists attempts per message and the delays between them.
   Kick unsubscribes an app whose webhook keeps failing "for over a day", so
   keep failure windows short.
5. Clean up when done:

   ```bash
   mix record.subscribe --delete-all
   ```

### 6. Anonymize into fixtures

```bash
mix fixtures.anonymize
```

It prints every field whose text was kept without a rule (paths only). **Read
that list before committing `fixtures/`.** If a listed path can hold
something personal, add a rule to `Sim.Fixtures.Anonymizer` (with a test)
and run it again.

It then runs a **leak check**, independent of those rules: every real
username, slug, chat text and id found in the raw files is searched for in
the output. If any is found, the task fails, showing field paths (never
values). Don't commit `fixtures/` after a failed run. Then skim a few
fixture files yourself.

## Tests

```bash
mix test
```

Nothing in the tests talks to Kick: signatures use a generated key, the
webhook capture runs through `Plug.Test`, and the Pusher recorder is tested
against a local fake Pusher server.
