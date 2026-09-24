# RabbitMQ

`definitions.dev.json` is the topology from `project.md` §8.3, loaded by
RabbitMQ at boot:

- exchange `kick.events` (topic), where receivers publish, routing key = event type;
- quorum queue `kick_tracker.events`, bound with `#`, which the app consumes;
  after 10 failed deliveries a message goes to
- `kick.events.dlx` (fanout) → `kick_tracker.events.dead`, inspected and
  replayed by hand, never dropped silently.

Users, each with only what it needs:

| User | May | Development password |
|---|---|---|
| `receiver` | publish to `kick.events`, nothing else | `receiver-dev` |
| `app` | consume `kick_tracker.events`, nothing else | `app-dev` |
| `ops` | read the dead-letter queue and publish to `kick.events` (the admin's dead-letter page: inspect, replay, discard) | `ops-dev` |
| `monitor` | read queue depths over the management API (health page), nothing else | `monitor-dev` |
| `admin` | everything (management UI, tests) | `admin-dev` |

The same topology and permissions exist twice: in vhost `/` for development
and in vhost `test` for automated tests, so tests never publish into the
development queue.

These passwords are for the local development broker only
(`deploy/compose.dev.yml`, bound to 127.0.0.1). Production gets its own
users and passwords, never these. Hashes are made with
`rabbitmqctl hash_password <password>`.

Management UI in development: http://127.0.0.1:15673 (admin / admin-dev).
