# Ingress failover Worker

A Cloudflare Worker on the webhook hostname (project.md §15.2). Kick sends
every webhook to one address; this Worker sends each one to the main VPS's
receivers, and if they can't take it (no connection, no answer within
`MAIN_TIMEOUT_MS`, or a 5xx) sends the same request to the backup receiver
on the shadow machine, which spools it and forwards it to the main
RabbitMQ once that answers again.

It retries per request rather than waiting for a health check, because
Kick doesn't seem to redeliver a webhook that failed (KICK.md): a
delivery sent while the main VPS is going down would otherwise be lost.
A 4xx (a bad signature, a replay) is the receiver's answer and is passed
back as it is. The body and Kick's headers go on untouched, so the
receivers still verify Kick's signature; the answer carries
`x-ingress-target: main|backup`.

No dependencies: `src/worker.js` is the whole Worker.

## Test

    npm test          # node --test, Node 20 or later

## Deploy

1. The backup receiver's hostname: a public hostname on the shadow
   machine's Cloudflare Tunnel, to `http://localhost:4060`. The main VPS
   needs nothing new: the Worker reaches it through the webhook hostname
   itself, since a Worker's `fetch()` to its own zone goes straight to the
   origin (never turn on the `global_fetch_strictly_public` flag here; a
   request that comes back to the Worker anyway is refused with a 508).
2. `cp wrangler.toml.example wrangler.toml` (git-ignored) and fill in the
   route and `BACKUP_URL`.
3. `npx wrangler deploy` (asks to log in to Cloudflare the first time).

Check it: `curl -si https://<ingress host>/health` answers with
`x-ingress-target: main`. The failover test is in deploy/README.md,
"The shadow machine".
