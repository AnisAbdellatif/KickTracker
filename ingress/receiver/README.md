# receiver

What Kick's webhooks reach (project.md §8.4). For each delivery it:

1. checks the `Kick-Event-*` headers against the envelope schema's limits
   (`contracts/envelope.schema.json`); a header that breaks them gets 400;
2. checks Kick's signature; if it fails, it refetches Kick's key (at most
   once a minute, in the background, waiting for it at most 3s) in case the
   key changed, and retries only with a different key; a bad one gets 401;
3. refuses (400) a delivery whose signed timestamp is older than
   `MAX_EVENT_AGE_S`, so a captured delivery can't be replayed much later;
4. wraps the delivery in the envelope from `contracts/envelope.md`;
5. publishes it to RabbitMQ (`kick.events`) and waits for the broker's
   confirm, as `mandatory` so a message nothing would receive is caught;
6. if that fails in any way (including no confirm within
   `CONFIRM_TIMEOUT_MS`, or the broker blocking publishers during an
   alarm), writes the envelope to a local SQLite spool;
7. answers 200.

200 always means the delivery is safe: confirmed by RabbitMQ or on this
machine's disk. If neither works it answers 503, so Kick retries. The
forwarder drains the spool once RabbitMQ is back, deleting each envelope
only after its confirm.

It never touches the app's database and holds no app secret: only Kick's
public key and a publish-only RabbitMQ user.

## Running it locally

```bash
docker compose -f ../../deploy/compose.dev.yml up -d
(cd ../../sim && mix sim --webhook-url http://127.0.0.1:4060/)
mix run --no-halt
```

`GET http://127.0.0.1:4060/health` answers `{"ok", "rabbitmq", "spooled",
"spool_bytes", "spool_over_limit"}`. It never waits on RabbitMQ or on a
publish in progress (the connection state is read from memory), so the
load balancer's 2s health timeout holds whatever the broker does.

It answers **503** when the spool doesn't respond, and when RabbitMQ has
been unreachable for more than `HEALTH_BROKER_GRACE_S` **while the peer
receiver (`PEER_HEALTH_URL`) reports it can publish**. Behind Caddy's
`lb_policy first`, that moves deliveries to the peer instead of piling
them up in this receiver's spool. When neither receiver can reach
RabbitMQ (the broker is down), both stay 200 and spool, since refusing
would only turn an outage into lost webhooks. Without `PEER_HEALTH_URL`
a receiver never steps aside.

The spool has no hard size limit (dropping deliveries is worse than
filling a disk): past `SPOOL_WARN_BYTES` `/health` sets
`spool_over_limit`, for an alert, and keeps accepting.

## Configuration

| Variable | Meaning | Development default |
|---|---|---|
| `PORT` | where Kick (or the load balancer) sends deliveries | `4060` |
| `RECEIVER_ID` | this receiver's name, written into every envelope | `dev/1` |
| `LISTEN_IP` | the address to listen on | `127.0.0.1` in development, `0.0.0.0` in production |
| `KICK_PUBLIC_KEY` | Kick's signing key (PEM); fetched from the API if unset | — |
| `KICK_API_URL` | where to fetch it | the fake Kick, `http://127.0.0.1:4050` |
| `AMQP_URL` | RabbitMQ, as the publish-only `receiver` user | the local broker |
| `AMQP_EXCHANGE` | where to publish | `kick.events` |
| `SPOOL_PATH` | the spool's SQLite file | `spool.sqlite3` |
| `CONFIRM_TIMEOUT_MS` | how long to wait for RabbitMQ's confirm before spooling, in ms; a delivery waits at most this plus 1s | `5000` |
| `MAX_EVENT_AGE_S` | refuse deliveries signed longer ago than this (Kick retries for about a day, so keep it lenient); `0` turns it off | `259200` (3 days) |
| `HEALTH_BROKER_GRACE_S` | how long RabbitMQ may be unreachable before `/health` says 503, if the peer can publish | `30` |
| `PEER_HEALTH_URL` | the other receiver's `/health`, e.g. `http://receiver-2:4060/health`; unset, never step aside | — |
| `SPOOL_WARN_BYTES` | spool size past which `/health` reports `spool_over_limit` | `1073741824` (1 GiB) |

In production every value without a default must be set.

## Tests

```bash
mix test
```

They need the development broker (`deploy/compose.dev.yml`) and use its
`test` vhost, so they never touch development data. Envelopes are checked
against `contracts/envelope.schema.json`.
