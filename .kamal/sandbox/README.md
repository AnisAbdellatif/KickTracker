# The sandbox

The production stack on this machine, deployed exactly as production is:
deploy-kit and Kamal, both Kamal configs, the groups (the collectors'
handover, the web nodes and receivers one at a time), the migrations step
and the smoke tests. Only the "server" is a container here, and the fake
Kick (`sim/`) stands in for kick.com. The kit's `docs/sandbox.md`
(vendored: `.kamal/kit/`, and deploy-kit's repository) explains the
machinery; this is what KickTracker adds.

    .kamal/kit/bin/kit sandbox up          # build the working tree, start everything, first deploy, track the channels
    .kamal/kit/bin/kit sandbox deploy      # rebuild the working tree and deploy both configs
    .kamal/kit/bin/kit sandbox deploy --group web   # one group: only its config is built and deployed
    .kamal/kit/bin/kit sandbox status      # groups, containers, URLs
    .kamal/kit/bin/kit sandbox logs collector_a -f
    .kamal/kit/bin/kit sandbox exec web_a bin/kick_tracker remote
    .kamal/kit/bin/kit sandbox kit group switch collectors
    .kamal/kit/bin/kit sandbox down        # stop, keep the data
    .kamal/kit/bin/kit sandbox reset       # remove it and its data

Needs Docker and Elixir (the fake Kick runs from `sim/` on this machine;
the real Kick is opt-in, below). The first `up` takes a few minutes
(images, the fake Kick's compilation); later deploys about half a minute
per config.

Where things are:

| | |
|---|---|
| The site | http://localhost:8080 (through Caddy; the admin at `/admin`, signed in automatically, below) |
| The ingress | http://127.0.0.1:8080 (webhooks, as Kick reaches them) |
| The fake Kick | http://127.0.0.1:4050/_sim/state |
| The web nodes, directly | http://127.0.0.1:4110, http://127.0.0.1:4111 |

## The real Kick (opt-in)

By default the sandbox talks to the fake Kick. It can talk to the real
one instead, **through a Kick app of its own**, never production's:
webhook subscriptions belong to the Kick app, and the sandbox's collector
syncs them to what *it* tracks, removing the rest, so with production's
app it would unsubscribe production's channels (and the webhooks missed
meanwhile are gone for good).

1. Create a second app in Kick's developer settings, for the sandbox.
2. `cp .kamal/sandbox/kick.env.example .kamal/sandbox/kick.env` (git-ignored)
   and fill it in: that app's client id and secret, `PUSHER_URL` (the same
   as production's: `kit sops get deploy/secrets/collector.sops.env PUSHER_URL`),
   and the channels to track (`KT_SANDBOX_CHANNELS`), or leave that empty and
   add them in the admin.
3. Create the sandbox in that mode (the choice is made at creation and
   kept; switching needs a reset):

       .kamal/kit/bin/kit sandbox reset
       KT_SANDBOX_KICK=real .kamal/kit/bin/kit sandbox up

The secrets hook refuses a `kick.env` that isn't filled in, or that holds
production's client id (read with your sops key; without one it says it
couldn't check). The fake Kick isn't started. Polls (viewers, followers,
titles, categories) and chat work as soon as channels are tracked; add
them in the admin.

Webhooks go where the sandbox's Kick app says, which by default is
nowhere. To receive them, tunnel the sandbox's ingress to a public URL and
set it as that app's webhook URL, for example with Cloudflare's quick
tunnel (Caddy routes the ingress by host, hence the header):

    cloudflared tunnel --url http://127.0.0.1:8080 --http-host-header 127.0.0.1

Rate limits are per Kick app, so the sandbox's don't eat into
production's. The deploy rehearsal always uses the fake Kick.

## The admin

The admin at http://localhost:8080/admin needs no account: the web nodes
sign every visitor in as `admin@sandbox.localhost` (`ADMIN_AUTOLOGIN` in
the generated `app.env`, set by `site_settings` in `lib.sh` on every `up`;
a sandbox made before it gets it on its next `kit sandbox up` and web
deploy). Its actions are audited under that name. Fenced so it can't reach
production: the app refuses to start with `ADMIN_AUTOLOGIN` unless
`PHX_HOST` is `localhost` or `127.0.0.1`, and signs in only requests for
`localhost` (a tunnel to the ingress arrives as `127.0.0.1` and isn't let
in); Caddy's `/admin` allowlist and its listening on 127.0.0.1 still apply.
With the real Kick, the admin shows real chatters (and logged chat, where
turned on) to anything that can reach 127.0.0.1:8080 on this machine.

## What is where

| File | |
|---|---|
| `sandbox.env` | The kit's sandbox settings: both configs, and what `deploy/kamal/*.yml` read from the environment (`KT_HOST`… for the sandbox; volumes prefixed `kicktracker-sandbox`) |
| `../kit.sandbox.env` | The kit's settings for the `sandbox` destination: pre-deploy steps without the server's checkout sync; smoke tests on the site through Caddy |
| `../secrets.sandbox` | Kamal's secret for the sandbox's registry (not a secret) |
| `../../deploy/kamal/*.sandbox.yml` | Kamal's `sandbox` destination: every role on 127.0.0.1, SSH and registry the sandbox's, the fake Kick's host |
| `../../deploy/compose.sandbox.yml` | The compose stack's differences: plain HTTP on 127.0.0.1:8080, no other published port |
| `scenario.exs` | The fake Kick's channels (three always live) |
| `kick.env.example` | The real Kick's settings for the sandbox's own Kick app (opt-in; copied to `kick.env`, git-ignored) |
| `lib.sh` | Shared by the hooks |
| `secrets` | Before the first deploy: the "server's checkout" (a copy of `deploy/`, mounted at `/srv/kick_tracker/deploy`) with generated secrets, RabbitMQ's definitions for them |
| `services-up` | The database, RabbitMQ and Caddy (compose, project `kicktracker-sandbox`), and the fake Kick |
| `seed` | After the first deploy: the scenario's channels tracked |
| `urls` | Where things are |
| `services-down`, `reset` | Stop them; remove them and every sandbox volume |

The deploy rehearsal (`deploy/rehearsal/`) runs on this sandbox.
