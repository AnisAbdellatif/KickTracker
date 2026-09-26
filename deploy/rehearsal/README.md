# Deploy rehearsal

The sandbox (`kit sandbox`, [`.kamal/sandbox/`](../../.kamal/sandbox/README.md):
the production stack on this machine, deployed by the kit and Kamal as
production is) kept busy and upgraded the way production is upgraded, with
what each step costs measured. Run it before trusting a change to the
deploy path, and before a first real deploy.

    deploy/rehearsal/rehearse.sh          # about 30 minutes, then a report
    deploy/rehearsal/rehearse.sh report   # the report again, from the running sandbox
    deploy/rehearsal/rehearse.sh down     # remove the sandbox and its data

What it does:

1. Resets the sandbox (**a sandbox already running loses its data**) and
   brings it up fresh: the working tree built into the sandbox's registry
   (`sandbox-1`), the database, RabbitMQ and Caddy (compose, as in
   production), the fake Kick with three always-live channels, both Kamal
   configs deployed through the kit (migrations, the collectors bootstrapped,
   the web nodes, the receivers), the channels tracked.
2. Builds `rehearsal-v2`: `sandbox-1` plus a migration on `viewer_samples`
   (a hypertable the collectors write to all the time); the receiver's v2
   is the same image under another tag, so its containers are still
   replaced.
3. Keeps it busy: a request to the site every second through Caddy, a gift
   webhook every 3s per channel through the ingress, polls and chat.
4. Runs, each followed by a minute and a bit of settling: web deploy to v2
   (with its migration), collector deploy (the standby, then the
   handover), receiver deploy, database restart, RabbitMQ restart, the
   collecting container killed (and started again, as Docker's restart
   policy would after a real crash: it skips containers killed by hand), a
   rollback of web to v1, the collectors switched (`kit group switch`, the
   collectors' rollback), and a whole release to v2 (both configs, with the
   smoke tests through Caddy armed). Every kit command goes through `kit
   sandbox kit`, which first checks that Kamal would deploy only to this
   machine.
5. Writes `.work/report.md`: operations that failed, failed site requests
   and the longest outage per operation, viewer readings per channel per
   minute (gaps), chat, who collected when, the journals, webhooks
   delivered by the fake Kick against those stored (giving deliveries in
   flight 30s to land), the cluster, open alerts, and what runs at the end.
   `.work/log/ops.log` has the kit's and Kamal's own output for every
   operation.

The sandbox keeps running afterwards: `kit sandbox status` shows it, and
the site is on http://localhost:8080. What differs from production is the
sandbox's (its README): the server is a container, images come from a
local registry, the kit's git, CI and attestation gates and the server's
checkout sync are skipped, plain HTTP on `127.0.0.1:8080`, backups to a
local WAL-G store, and the fake Kick instead of kick.com.
