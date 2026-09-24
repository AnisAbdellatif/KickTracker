# receiver

What Kick's webhooks reach (project.md §8.4). For each delivery it:

1. checks Kick's signature (refetching Kick's key once, at most once a
   minute, if a signature fails, in case the key changed); a bad one gets 401;
2. wraps the delivery in the envelope from `contracts/envelope.md`;
3. publishes it to RabbitMQ (`kick.events`) and waits for the broker's
   confirm, as `mandatory` so a message nothing would receive is caught;
4. if that fails in any way, writes the envelope to a local SQLite spool;
5. answers 200.

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

`GET http://127.0.0.1:4060/health` answers `{"ok", "rabbitmq", "spooled"}`.

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
| `CONFIRM_TIMEOUT_MS` | how long to wait for RabbitMQ's confirm | `5000` |

In production every value without a default must be set.

## Tests

```bash
mix test
```

They need the development broker (`deploy/compose.dev.yml`) and use its
`test` vhost, so they never touch development data. Envelopes are checked
against `contracts/envelope.schema.json`.
