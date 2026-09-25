# Deploy rehearsal

The production stack on a development machine, upgraded the way production
is upgraded (deploy-kit and Kamal: `../release.sh`, `.kamal/`), while it is
kept busy, with what each step costs measured. Run it before trusting a
change to the deploy path, and before the first real deploy.

    deploy/rehearsal/rehearse.sh        # about 30 minutes, then a report
    deploy/rehearsal/rehearse.sh down   # remove the stack and its volumes

What it does:

1. Builds the app, receiver and database images from the working tree
   (`rehearsal-v1`, labelled for Kamal as CI labels them), a
   `rehearsal-v2` app image that adds a migration on `viewer_samples` (a
   hypertable the collectors write to all the time), and the helper image
   (`tools/Dockerfile`). The app and receiver images go to a local
   registry on `127.0.0.1:5555`.
2. Copies `deploy/` to `.work/deploy` with generated local secrets and
   RabbitMQ definitions, starts **the server** (a container running sshd
   on `127.0.0.1:2222`, with a Docker CLI on this machine's Docker and the
   copy where the server's checkout would be), and starts the fake Kick
   (`sim/`) on the host with three always-live channels (`scenario.exs`).
3. Starts the database and the queue (compose, on Kamal's network), then
   deploys as in production from **the deployer** (a container with Kamal
   and the kit, playing the machine that deploys): `kit deploy --bootstrap`
   (migrations, the collectors, the web nodes), `kit deploy -c
   deploy/kamal/receiver.yml`, then Caddy. All clustered.
4. Keeps it busy: a request to the site every second through Caddy, a
   gift webhook every 3s per channel through the ingress, polls and chat.
5. Runs, each followed by a minute and a bit of settling: web deploy to v2
   (with its migration), collector deploy (the standby, then the
   handover), receiver deploy, database restart, RabbitMQ restart, the
   collecting container killed (and started again, as Docker's restart
   policy would after a real crash: it skips containers killed by hand), a
   rollback of web to v1, the collectors switched (`kit group switch`, the
   collectors' rollback), and a whole release to v2 (both configs, with the
   smoke tests through Caddy armed).
6. Writes `.work/report.md`: operations that failed, failed site requests
   and the longest outage per operation, viewer readings per channel per
   minute (gaps), chat, who collected when, the journals, webhooks
   delivered by the fake Kick against those stored, the cluster, open
   alerts, and what runs at the end. `.work/log/ops.log` has the kit's and
   Kamal's own output for every operation.

Only what a laptop can't do differs from production: the server is a
container (`kamal/*.rehearsal.yml` adds the fake Kick's host to the app's
containers; `.kamal/kit.rehearsal.env` drops the git, CI and attestation
gates and the server's checkout sync, which have nothing to check here),
images come from a local registry, plain HTTP on `127.0.0.1:8080` instead
of HTTPS on 80/443 (`compose.rehearsal.yml`), backups to a local WAL-G
store, and the fake Kick instead of kick.com.

The containers use this machine's Docker with user namespaces off
(`--userns=host`) where they need its network.
