# sim

The fake Kick (phase 1, not built yet) and the **recorder** (phase 0): small
tasks, run by hand, that record what the real Kick sends so the simulator and
the parser tests can be built from real payloads (`project.md` §17).

The recorder is the **only** code allowed to call the real Kick before
phase 5 (`AGENTS.md` §6). Keep runs short and on one or two channels.

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
