# app

The tracker itself: a Phoenix app that runs as a `collector` (polling,
channel processes, the queue consumer) or as `web` (the site, admin and
`/data`), or both. Design: `../project.md` §10; rules: `../AGENTS.md`.

## Running it locally

```bash
docker compose -f ../deploy/compose.dev.yml up -d   # TimescaleDB and RabbitMQ
(cd ../sim && mix sim)                              # the fake Kick, in another terminal
mix setup                                           # deps, database, assets
mix phx.server                                      # http://localhost:4100
```

Development and tests talk to the fake Kick by default (see
`config/runtime.exs`); nothing here calls the real Kick.

`ROLE` picks what a node runs: `collector`, `web`, or `collector,web` (the
default outside production, where it must be set).

## Tests

```bash
mix test          # needs the compose database running
mix precommit     # compile with warnings as errors, format, test
```
