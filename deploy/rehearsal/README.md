# Deploy rehearsal

The production stack (`../compose.single.yml`) on a development machine,
upgraded the way production is upgraded (`../deploy.sh`), while it is kept
busy, with what each step costs measured. Run it before trusting a change
to the deploy path, and before the first real deploy.

    deploy/rehearsal/rehearse.sh        # about 25 minutes, then a report
    deploy/rehearsal/rehearse.sh down   # remove the stack and its volumes

What it does:

1. Builds the app, receiver and database images from the working tree
   (`rehearsal-v1`), and a `rehearsal-v2` app image that adds a migration
   on `viewer_samples` (a hypertable the collectors write to all the time).
2. Copies `deploy/` to `.work/deploy` with generated local secrets and
   RabbitMQ definitions, and starts the fake Kick (`sim/`) on the host with
   three always-live channels (`scenario.exs`).
3. Starts the stack as in production: database and queue, `migrate`, then
   Caddy, both receivers, both collectors, both web nodes, all clustered.
4. Keeps it busy: a request to the site every 200ms through Caddy, a gift
   webhook every 3s per channel through the ingress, polls and chat.
5. Runs, each followed by a minute and a bit of settling:
   web deploy to v2 (with its migration), collector deploy, receiver
   deploy, database restart, RabbitMQ restart, the collecting container
   killed, and a rollback of web and collectors to v1.
6. Writes `.work/report.md`: failed site requests and the longest outage
   per operation, viewer readings per channel per minute (gaps), chat,
   who collected when, the journals, webhooks delivered by the fake Kick
   against those stored, the cluster, open alerts.

Only what a laptop can't do differs from production
(`compose.rehearsal.yml`): plain HTTP on `127.0.0.1:8080` instead of
HTTPS on 80/443, backups to a local WAL-G store instead of object storage,
and the fake Kick on the host instead of kick.com.
