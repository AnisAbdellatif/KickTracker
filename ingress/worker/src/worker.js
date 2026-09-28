// The webhook failover (project.md §15.2): a Cloudflare Worker on the
// ingress hostname, in front of the two places a webhook can land. Each
// request goes to the main VPS's receivers first; if they can't take it
// (no connection, no answer in time, or a 5xx), the same request goes to
// the backup receiver on the shadow machine, which spools it and forwards
// it to the main RabbitMQ once that answers again.
//
// Kick doesn't seem to redeliver a webhook that failed (KICK.md), so this
// retries each request itself instead of waiting for a health check to
// notice the main VPS is gone. The body and Kick's headers are passed on
// untouched: the receivers verify Kick's signature over them. A webhook
// delivered to both (the main one took it but its answer was lost) is
// harmless: the app ignores repeats by message id.
//
// Settings (wrangler.toml [vars]): MAIN_URL and BACKUP_URL, each an
// origin like https://ingress-main.<domain>, never the hostname this
// Worker is routed on; MAIN_TIMEOUT_MS (default 5000) and
// BACKUP_TIMEOUT_MS (default 10000).

// Headers that describe the hop to this Worker, not the delivery.
const HOP_HEADERS = ["host", "content-length", "connection", "cf-connecting-ip", "cf-ray", "cf-visitor", "cf-ipcountry", "x-forwarded-proto", "x-real-ip"];

export default {
  async fetch(request, env) {
    return handle(request, env, fetch);
  },
};

export async function handle(request, env, fetchImpl) {
  const incoming = new URL(request.url);
  const targets = [
    { name: "main", origin: env.MAIN_URL, timeout: Number(env.MAIN_TIMEOUT_MS || 5000) },
    { name: "backup", origin: env.BACKUP_URL, timeout: Number(env.BACKUP_TIMEOUT_MS || 10000) },
  ];

  for (const t of targets) {
    if (!t.origin) return fail(500, `${t.name.toUpperCase()}_URL isn't set`);
    // Sending to the hostname this Worker is routed on would loop.
    if (new URL(t.origin).host === incoming.host) {
      return fail(500, `${t.name.toUpperCase()}_URL must not be this Worker's own hostname`);
    }
  }

  // Read once: a request body can only be consumed once, and both
  // attempts need it.
  const body = ["GET", "HEAD"].includes(request.method) ? undefined : await request.arrayBuffer();
  const headers = new Headers(request.headers);
  for (const h of HOP_HEADERS) headers.delete(h);

  let last = null;
  for (const t of targets) {
    const url = t.origin.replace(/\/$/, "") + incoming.pathname + incoming.search;
    try {
      const response = await fetchImpl(url, {
        method: request.method,
        headers,
        body,
        redirect: "manual",
        signal: AbortSignal.timeout(t.timeout),
      });
      // A 4xx is the receiver's answer about the delivery itself (a bad
      // signature, a replay): the other one would say the same.
      if (response.status < 500) return tagged(response, t.name);
      last = tagged(response, t.name);
      console.warn(`ingress: ${t.name} answered ${response.status}`);
    } catch (error) {
      console.warn(`ingress: ${t.name} failed: ${error?.name || error}`);
    }
  }

  // Neither could take it: Kick is told so, and may retry.
  return last || fail(502, "no receiver could take the delivery");
}

// Which receiver answered, for debugging deliveries (Kick ignores it).
function tagged(response, name) {
  const out = new Response(response.body, response);
  out.headers.set("x-ingress-target", name);
  return out;
}

function fail(status, message) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
