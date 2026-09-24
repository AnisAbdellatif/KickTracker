# Event envelope

The contract between the **ingress** (whatever receives Kick's webhooks) and
the **app** (which consumes them from the queue). It is the only thing the
two share. Background: `project.md` §8.

Envelope version: **1**. Schema: [`envelope.schema.json`](envelope.schema.json).

## The message

Every ingress turns one webhook delivery from Kick into one message whose
body is this JSON object (UTF-8):

```json
{
  "envelope_version": 1,
  "message_id": "01JH6X0T5B6Z6W9JQ3E4V8N2QK",
  "subscription_id": "01JH6WZQ7F0M1S8Y2D3C4B5A6V",
  "event_type": "livestream.status.updated",
  "event_version": "1",
  "sent_at": "2026-09-24T18:02:11Z",
  "signature": "k2c9…base64…==",
  "body": "{\"broadcaster\":{…},\"is_live\":true,…}",
  "received_at": "2026-09-24T18:02:11.482913Z",
  "receiver": "vps-a/1"
}
```

| Field | Type | Source | Rules |
|---|---|---|---|
| `envelope_version` | integer | ingress | `1` for this document. |
| `message_id` | string | `Kick-Event-Message-Id` | Kick's id for the delivery (a ULID). **The deduplication key.** Copied verbatim. |
| `subscription_id` | string | `Kick-Event-Subscription-Id` | Copied verbatim. |
| `event_type` | string | `Kick-Event-Type` | e.g. `livestream.status.updated`, `kicks.gifted`. Copied verbatim. |
| `event_version` | string | `Kick-Event-Version` | Kick's version of the event payload. Copied verbatim (a string, as the header is). |
| `sent_at` | string | `Kick-Event-Message-Timestamp` | Copied **verbatim, never reformatted**: it is part of the signed text. |
| `signature` | string | `Kick-Event-Signature` | Base64, copied verbatim. |
| `body` | string | request body | The raw request body, **byte for byte**, as a UTF-8 string. Never parsed and re-serialized: it is part of the signed text. |
| `body_base64` | string | request body | Used **instead of** `body` only if the raw body is not valid UTF-8. Exactly one of the two is present. |
| `received_at` | string | ingress clock | When the ingress received the request. RFC 3339, UTC (`Z`), microsecond precision. |
| `receiver` | string | ingress config | Which receiver instance took it, e.g. `vps-a/1`, `cloudflare/worker`. For tracing only. |

Unknown fields must be ignored by consumers (so new optional fields can be
added without a new envelope version).

## Signature

The app verifies again, trusting neither the queue nor the ingress. The
signed text is:

```
<message_id>.<sent_at>.<raw body bytes>
```

verified with Kick's RSA public key (`GET /public/v1/public-key`, PEM), using
SHA-256 and PKCS#1 v1.5 padding, against the base64-decoded `signature`.
This is why `message_id`, `sent_at` and `body` must be copied exactly.

The ingress also verifies before publishing and **rejects** (HTTP 401, not
published) a delivery whose signature fails. Only verified deliveries enter
the queue.

## Transport (RabbitMQ)

| | Value |
|---|---|
| Exchange | `kick.events` (topic, durable) |
| Routing key | `event_type` |
| `content_type` | `application/json` |
| `message_id` property | same as `message_id` |
| `type` property | same as `event_type` |
| `timestamp` property | `received_at`, in Unix seconds |
| `delivery_mode` | 2 (persistent) |
| Publishing | With publisher confirms. The ingress answers Kick 200 only after the confirm, or after writing the envelope to its local spool. |

Another queue can replace RabbitMQ as long as the guarantees below hold; the
body of the message is the same envelope.

## Guarantees: what the app may assume, and nothing more

1. **At-least-once.** Any envelope can arrive more than once (Kick retries,
   two receivers, spool replays, redelivery after a crash). The app ignores
   repeats by `message_id`.
2. **No ordering.** Envelopes can arrive in any order, including across
   event types ("offline" before the "online" it follows). The app uses the
   payload's own timestamps and the stream's `started_at`, never arrival
   order.
3. **Ack after commit.** The app acknowledges only after the envelope is
   durably stored in its database. Anything unacknowledged is redelivered.
4. **Short retention.** The queue is a buffer, not a record. The app's
   `webhook_events` table is the permanent record.
5. **Verified at the edge, verified again.** Every envelope passed the
   ingress's signature check; the app checks again and dead-letters any that
   fail.

## Versioning

- Adding an **optional** field: same `envelope_version`. Consumers ignore
  unknown fields.
- Anything else (removing or renaming a field, changing a type or meaning):
  new `envelope_version`, and consumers read both versions until every
  ingress has moved.
- Kick's own payload versions travel in `event_version` and are the
  consumer's concern, not the envelope's.

## Conformance

Every ingress implementation has a test that produces envelopes and
validates them against `envelope.schema.json`, including a signature check
against the original request.
