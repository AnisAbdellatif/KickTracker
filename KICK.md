# Kick: what we know

Everything this project has learnt about Kick as a data source (the
official API and webhooks, Kick's own website endpoints, the realtime chat
feed), each fact with where it was seen, now lives in **kicksdk**, the
library this project talks to Kick through:

**[kicksdk `docs/KICK.md`](https://github.com/AnisAbdellatif/kicksdk/blob/main/docs/KICK.md)**

It is the one copy. When Kick behaves differently from what is written
there, correct it there first, then kicksdk's fixtures and code, then
update the `kicksdk` dependency here: a change on Kick's side is fixed once,
in kicksdk, for every project using it. Section numbers cited in this repo
(`KICK.md §6.3`) are that file's; they were this file's before it moved and
are unchanged.

What stays here is how KickTracker uses it. The design built on these facts
is [project.md](project.md) (§2 sources, §3 cadences, §16 open questions);
the reasons for each choice are in [decisions.md](decisions.md).

## Where this lives in the repo

| What | Where |
|---|---|
| Every Kick URL and key | configuration: `KICK_API_URL`, `KICK_ID_URL`, `KICK_V2_URL`, `KICK_REALTIME_URL`, `KICK_PUBLIC_KEY`, `KICK_FILES_URL`; as kicksdk's endpoints map in `app/lib/kick_tracker/kick/endpoints.ex` |
| Sending what kicksdk builds | `app/lib/kick_tracker/kick/http.ex` (Req, our User-Agent) |
| Public API, token, public key | `app/lib/kick_tracker/kick/` (`api.ex`, `token.ex`, `public_key.ex`) |
| v2 (followers, chatroom id) | `app/lib/kick_tracker/kick/v2.ex` |
| Webhook signature | `app/lib/kick_tracker/kick/signature.ex`, `ingress/receiver/lib/receiver/signature.ex` (our own, from before kicksdk 0.2.0's verify took raw bytes; decisions.md, "Kick through kicksdk") |
| Webhook bodies into facts | `app/lib/kick_tracker/events/facts.ex` |
| The chat feed (Centrifugo) | `app/lib/kick_tracker/tracking/chat_socket.ex`; reconnects as kicksdk's §6.1 table says (terminal closes wait on `Kicksdk.Realtime.Backoff`) |
| Hosts | `app/lib/kick_tracker/channel_events.ex` |
| Emotes in the chat log | `app/lib/kick_tracker/chat_log.ex` |
| Webhook subscriptions | `app/lib/kick_tracker/workers/subscription_sync.ex` |
| Webhook receiver | `ingress/receiver/`; the envelope: `contracts/envelope.md` |
| Recorder and anonymizer (API, v2, webhooks, probes) | `sim/` (`mix record.*`, `mix fixtures.anonymize`; runbook `sim/README.md`). The realtime feed is recorded by kicksdk's `tools/record-realtime.mjs` |
| Recorded, anonymized payloads | `fixtures/` (`fixtures/pusher`: the chat feed while it was Pusher; Kick's event data inside is unchanged); kicksdk's `fixtures/` |
| The fake Kick all tests run against | `sim/` |
