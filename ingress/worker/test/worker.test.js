// node --test ingress/worker/test
import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../src/worker.js";

const env = {
  MAIN_URL: "https://ingress-main.example.test",
  BACKUP_URL: "https://ingress-backup.example.test",
  MAIN_TIMEOUT_MS: "50",
  BACKUP_TIMEOUT_MS: "50",
};

const delivery = () =>
  new Request("https://ingress.example.test/webhooks/kick?x=1", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "kick-event-message-id": "01J0000000000000000000000",
      "kick-event-signature": "c2lnbmF0dXJl",
      "cf-connecting-ip": "203.0.113.7",
    },
    body: '{"broadcaster":{"user_id":1234567}}',
  });

// A fetch that answers per origin and records what it was sent.
function fake(answers) {
  const calls = [];
  const impl = async (url, init) => {
    const origin = new URL(url).origin;
    calls.push({ url, method: init.method, headers: init.headers, body: init.body && Buffer.from(init.body).toString() });
    const answer = answers[origin];
    if (answer === "hang") {
      return new Promise((_, reject) =>
        init.signal.addEventListener("abort", () => reject(init.signal.reason)),
      );
    }
    if (answer instanceof Error) throw answer;
    return new Response(answer.body ?? "{}", { status: answer.status });
  };
  return { impl, calls };
}

test("a delivery goes to the main VPS, untouched", async () => {
  const { impl, calls } = fake({ [env.MAIN_URL]: { status: 200, body: '{"ok":true}' } });
  const res = await handle(delivery(), env, impl);

  assert.equal(res.status, 200);
  assert.equal(res.headers.get("x-ingress-target"), "main");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://ingress-main.example.test/webhooks/kick?x=1");
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].body, '{"broadcaster":{"user_id":1234567}}');
  assert.equal(calls[0].headers.get("kick-event-signature"), "c2lnbmF0dXJl");
  assert.equal(calls[0].headers.get("kick-event-message-id"), "01J0000000000000000000000");
  assert.equal(calls[0].headers.get("cf-connecting-ip"), null);
});

test("the main VPS unreachable: the same delivery goes to the backup", async () => {
  const { impl, calls } = fake({
    [env.MAIN_URL]: new TypeError("network connection lost"),
    [env.BACKUP_URL]: { status: 200, body: '{"ok":true,"spooled":true}' },
  });
  const res = await handle(delivery(), env, impl);

  assert.equal(res.status, 200);
  assert.equal(res.headers.get("x-ingress-target"), "backup");
  assert.deepEqual(calls.map((c) => new URL(c.url).origin), [env.MAIN_URL, env.BACKUP_URL]);
  assert.equal(calls[1].body, calls[0].body);
  assert.equal(calls[1].headers.get("kick-event-signature"), "c2lnbmF0dXJl");
});

test("the main VPS not answering in time counts as unreachable", async () => {
  const { impl } = fake({ [env.MAIN_URL]: "hang", [env.BACKUP_URL]: { status: 200 } });
  const res = await handle(delivery(), env, impl);
  assert.equal(res.headers.get("x-ingress-target"), "backup");
});

test("a 5xx from the main VPS goes to the backup", async () => {
  const { impl } = fake({ [env.MAIN_URL]: { status: 503 }, [env.BACKUP_URL]: { status: 200 } });
  const res = await handle(delivery(), env, impl);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("x-ingress-target"), "backup");
});

test("a 4xx is the receiver's answer and isn't retried", async () => {
  const { impl, calls } = fake({ [env.MAIN_URL]: { status: 401, body: '{"error":"bad signature"}' } });
  const res = await handle(delivery(), env, impl);
  assert.equal(res.status, 401);
  assert.equal(calls.length, 1);
});

test("neither can take it: Kick gets an error, never a 2xx", async () => {
  const { impl } = fake({ [env.MAIN_URL]: new TypeError("down"), [env.BACKUP_URL]: { status: 503 } });
  assert.equal((await handle(delivery(), env, impl)).status, 503);

  const both = fake({ [env.MAIN_URL]: new TypeError("down"), [env.BACKUP_URL]: new TypeError("down") });
  assert.equal((await handle(delivery(), env, both.impl)).status, 502);
});

test("without MAIN_URL, the main VPS is the Worker's own hostname (fetch goes to the origin)", async () => {
  const { impl, calls } = fake({ "https://ingress.example.test": { status: 200 } });
  const res = await handle(delivery(), { ...env, MAIN_URL: undefined }, impl);
  assert.equal(res.headers.get("x-ingress-target"), "main");
  assert.equal(calls[0].url, "https://ingress.example.test/webhooks/kick?x=1");
});

test("its own requests are marked, and one coming back to it is refused, not looped", async () => {
  const { impl, calls } = fake({ [env.MAIN_URL]: { status: 200 } });
  await handle(delivery(), env, impl);
  assert.equal(calls[0].headers.get("x-ingress-worker"), "1");

  const looped = new Request("https://ingress.example.test/webhooks/kick", {
    method: "POST",
    headers: { "x-ingress-worker": "1" },
    body: "{}",
  });
  const again = fake({});
  const res = await handle(looped, env, again.impl);
  assert.equal(res.status, 508);
  assert.equal(again.calls.length, 0);
});

test("BACKUP_URL unset is an error, not a silent single target", async () => {
  const { impl, calls } = fake({});
  const res = await handle(delivery(), { ...env, BACKUP_URL: "" }, impl);
  assert.equal(res.status, 500);
  assert.equal(calls.length, 0);
});

test("health checks pass through the same way", async () => {
  const { impl, calls } = fake({ [env.MAIN_URL]: { status: 200, body: '{"ok":true}' } });
  const res = await handle(new Request("https://ingress.example.test/health"), env, impl);
  assert.equal(res.status, 200);
  assert.equal(calls[0].body, undefined);
});
