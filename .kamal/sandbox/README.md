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
    .kamal/kit/bin/kit sandbox deploy -c deploy/kamal/app.yml --group web   # one group (name its config: see below)
    .kamal/kit/bin/kit sandbox status      # groups, containers, URLs
    .kamal/kit/bin/kit sandbox logs collector_a -f
    .kamal/kit/bin/kit sandbox exec web_a bin/kick_tracker remote
    .kamal/kit/bin/kit sandbox kit group switch collectors
    .kamal/kit/bin/kit sandbox down        # stop, keep the data
    .kamal/kit/bin/kit sandbox reset       # remove it and its data

Needs Docker and Elixir (the fake Kick runs from `sim/` on this machine).
The first `up` takes a few minutes (images, the fake Kick's compilation);
later deploys about half a minute per config.

Where things are:

| | |
|---|---|
| The site | http://localhost:8080 (through Caddy; the admin at `/admin`) |
| The ingress | http://127.0.0.1:8080 (webhooks, as Kick reaches them) |
| The fake Kick | http://127.0.0.1:4050/_sim/state |
| The web nodes, directly | http://127.0.0.1:4110, http://127.0.0.1:4111 |

`--group` with `kit sandbox deploy` must name its Kamal config (`-c`):
without it the kit passes the group to both configs, and the receivers'
has no `web` (it deploys web, then fails on the receivers).

## What is where

| File | |
|---|---|
| `sandbox.env` | The kit's sandbox settings: both configs, and what `deploy/kamal/*.yml` read from the environment (`KT_HOST`… for the sandbox; volumes prefixed `kicktracker-sandbox`) |
| `../kit.sandbox.env` | The kit's settings for the `sandbox` destination: pre-deploy steps without the server's checkout sync; smoke tests on the site through Caddy |
| `../secrets.sandbox` | Kamal's secret for the sandbox's registry (not a secret) |
| `../../deploy/kamal/*.sandbox.yml` | Kamal's `sandbox` destination: every role on 127.0.0.1, SSH and registry the sandbox's, the fake Kick's host |
| `../../deploy/compose.sandbox.yml` | The compose stack's differences: plain HTTP on 127.0.0.1:8080, no other published port |
| `scenario.exs` | The fake Kick's channels (three always live) |
| `lib.sh` | Shared by the hooks |
| `secrets` | Before the first deploy: the "server's checkout" (a copy of `deploy/`, mounted at `/srv/kick_tracker/deploy`) with generated secrets, RabbitMQ's definitions for them |
| `services-up` | The database, RabbitMQ and Caddy (compose, project `kicktracker-sandbox`), and the fake Kick |
| `seed` | After the first deploy: the scenario's channels tracked |
| `urls` | Where things are |
| `services-down`, `reset` | Stop them; remove them and every sandbox volume |

The deploy rehearsal (`deploy/rehearsal/`) runs on this sandbox.
