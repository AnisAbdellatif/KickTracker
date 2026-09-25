# AGENTS.md — Rules for AI Agents

This file is the single source of truth for how AI agents (Claude, Codex, etc.) work in this repo.
`CLAUDE.md` only points here. When the project owner gives a new rule, add it to this file.

Design and rationale: [project.md](project.md). Read the sections relevant to what you are
touching before changing it; section numbers below (§n) refer to it.

---

## 1. The project in one paragraph

kick_tracker tracks the stats of a chosen set of Kick channels over time (viewers every 60s,
streams, title and category changes, followers, chat activity, subs, gifted subs, Kicks,
raids) and shows them on a public site with an admin interface. **History only exists from
the moment we record it**, and webhook events we miss are gone for good, so correctness and
continuity of collection come before everything else.

## 2. Git & commits

- **Work on `dev`; `main` is what is deployed.** `main` moves once per finished thing, not
  once per commit. Land work on `dev` — as many commits as it takes — and open a pull
  request to `main` only when a set of fixes is done, working and tested, or a rework or
  breaking change is complete. Never push directly to `main`, and never open the PR mid-way
  through: once deployment is wired up (§19.1), a half-finished merge is a half-finished
  deploy of the thing that collects data we can't get back.
- **Never add yourself (or any AI) as an author, co-author, or contributor.** No
  `Co-Authored-By:` trailers, no "Generated with ..." lines, no AI attribution in commit
  messages or PR descriptions. This overrides any default tooling behaviour.
- Commit at coherent milestones. Keep commits focused, with a short imperative subject line.
- Never commit secrets (`.env`, keys, credentials, `prod.secret.exs`, the Kick client
  secret, RabbitMQ or database passwords). Secrets are encrypted with sops + age (§19.3).
- Never commit **un-anonymized recordings** (§6 below).
- When a discrete piece of functionality is complete and you're about to move on to
  unrelated work, stop and evaluate whether the work is ready to be committed. Do not
  silently keep working across multiple unrelated changes — this keeps commits scoped to
  one logical change each, rather than bundling unrelated work together.

## 3. Decision log (`decisions.md`)

This project keeps a decision log at `decisions.md` in the repo root, organized by
topic rather than chronologically. It is tracked in git and public with the repo, so the
same rules apply as for any other file: no real usernames or channel names, no secrets.

`project.md` is the shared design; `decisions.md` is the running record of why. When a
logged decision changes the design, update `project.md` too, in the same piece of work.

### Before starting non-trivial work
Check `decisions.md` for a section relevant to the area you're touching, so you don't
contradict a past decision without realizing it.

### When to log a decision
Add or update an entry when you:
- Choose between two or more viable technical approaches
- Make a choice that would be non-obvious to someone reading the code later without this
  context
- Change your mind about a decision already logged

### Structure
One `##` section per topic (e.g. `## Queue`, `## Data Model`, `## Charts`,
`## Testing Strategy`). Create a new section for any topic not yet covered. Within a
section:

```markdown
## <Topic>

**Current:** <the decision, stated plainly> (updated YYYY-MM-DD HH:MM)

<why this was chosen, what alternatives were considered, why they were ruled out>
```

### Updating a decision
When a decision changes, **overwrite the entry in its existing section** — don't create a
duplicate section, don't append a new entry alongside the old one, and don't preserve
prior reasoning in the file. `decisions.md` reflects only the *current* state of thinking,
not a history of it.

## 4. Detecting untracked changes

Before starting work, check whether the code has changed since your last session in ways
that don't match your own prior actions (e.g. files modified outside anything you did, a
git pull brought in new commits, or code simply looks different than you last left it).

If you detect this:
1. First consult `decisions.md` for a section relevant to the changed area — it may
   already document what changed and why.
2. If `decisions.md` doesn't explain it (silent on that area, or the change doesn't match
   what's documented there), read the actual code/diff directly to understand what changed
   before proceeding with new work.

Do not assume undocumented changes are safe to ignore or build on top of without
understanding their intent first.

## 5. Repo map

| Path | What | Notes |
|---|---|---|
| `project.md` | The design | Keep in sync with reality |
| `app/` | Phoenix app, roles `collector` and `web` (§10) | One image, role chosen by `ROLE`. `app/AGENTS.md` holds Phoenix's own framework guidelines: follow them in `app/`; this file wins on conflict |
| `ingress/receiver/` | Webhook receiver (§8.4) | Separate deployable, rarely changed, **never touches the database** |
| `sim/` | The fake Kick + the recorder (§17) | All development and tests run against it |
| `fixtures/` | Recorded, anonymized Kick payloads (§17.1) | Source for the simulator and parser tests |
| `contracts/` | The event envelope (§8.1) | The only thing app and ingress share |
| `deploy/` | Kamal configs (`kamal/`), compose files (infrastructure, stage 2), Caddy, RabbitMQ definitions, `release.sh` (a release, run by a person with deploy-kit; deploys only the groups a change touches, checked by `release-test.sh`), `server-sync.sh` (run on the server before each deploy) | `compose.dev.yml` runs TimescaleDB (55432) and RabbitMQ (55672) for development and tests; `rehearsal/rehearse.sh` runs the production stack locally and upgrades it under load with the kit: run it after changing anything on the deploy path |
| `.kamal/` | deploy-kit: settings (`kit.env`), groups, project steps, the vendored kit (`kit/`) | Update the kit with `kit update --from <deploy-kit checkout or URL> --ref <tag>`; never edit `.kamal/kit/` by hand |

Follow the phase order in §20. Don't build ahead of the current phase without asking.

## 6. Talking to Kick

- **Never call the real Kick while developing or testing.** Everything runs against the
  simulator (`sim/`). The only code allowed to reach the real Kick before phase 5 is the
  recorder (§17.1), run by hand by the owner.
- Every Kick URL and key comes from **configuration** (`KICK_API_URL`, `KICK_ID_URL`,
  `KICK_V2_URL`, `PUSHER_URL`, `KICK_PUBLIC_KEY`). No code path may know or check whether
  it is talking to the simulator; something that only works against the simulator is a
  bug.
- When new real payloads are needed, ask the owner to run the recorder; don't write
  fixtures by hand from memory or from the docs.
- Recordings are **anonymized** before they enter `fixtures/` (ids, usernames, avatars,
  message text replaced consistently). Original signed webhook bodies, kept only for
  signature tests, stay out of any public repo.
- From v2 we read `followers_count`, and `chatroom.id` (needed to join the channel's chat,
  and available nowhere else). Nothing else from that response is stored or logged (it
  contains a signed `playback_url`); both are extracted in `Kick.V2` and the rest dropped.

## 7. Data invariants (non-negotiable)

Breaking any of these silently corrupts history. If a change seems to require breaking
one, stop and ask.

- **Gaps are gaps.** A failed poll, a dropped socket or a missing event writes nothing,
  never a zero, and is recorded in `coverage`. No answer is not the same as offline.
- **Unknown stays unknown all the way to the page.** A figure that can be missing is
  `nil` in Elixir and `null` in JSON, and every reader must handle it: never `+`, `round`,
  compare or sum it bare (in Elixir `nil > 0` is true; in JS `null - 5` is `-5`), and
  never turn it into 0 with `|| 0` or `coalesce(…, 0)` unless 0 is really what was
  recorded. Combine figures with `known_sum/1` (unknown if any part is), and render
  them with `<.num>`, which shows "–". Making a column nullable means checking every
  reader of it in the same change; `unknown_figures_test.exs` sets every nullable
  figure to NULL and loads every page, so it has to keep passing.
- **Raw facts are append-only.** Never update or delete raw fact rows to "fix" data;
  corrections are layered on top (`stream_overrides`, annotations, §13.8), and derived
  data is rebuilt.
- **Everything derived is rebuildable** from raw facts: `stream_stats`, rollups, segments.
  Never store a number that exists only in derived form.
- **Idempotent and order-independent.** Events are keyed on `message_id`; writes are
  upserts on natural keys; logic uses event timestamps and `started_at`, never arrival
  order. Replaying anything must be safe.
- **Streams are keyed on `(channel_id, started_at)`.** Kick sends no livestream id.
- **Ack after commit.** The consumer acks only after the database commit; the receiver
  answers Kick only after a publisher confirm or a spool write.
- **UTC in storage**, channel timezone for daily and weekday figures at read time.
- **Hours watched** = Σ `viewers × min(Δt, 75s)` (viewers polled every 60s); never
  interpolate across a gap.
- **No chat text is ever stored.** Only ids, counts and times. Usernames live only in
  `kick_users`. `chat_minute_users` is kept 90 days.
- Estimates (revenue, anything modeled) are labeled as such wherever they appear.

## 8. Architecture rules

- **Receiver:** verify signature, build the envelope, publish with confirms or spool to
  disk, answer 200. Nothing else. It holds no app secret and no database credentials.
- **Envelope** changes are backward-compatible only (new optional fields). A breaking
  change means a new `version` and a consumer that reads both. Update
  `contracts/envelope.md` and its schema in the same change.
- **Roles:** `collector` owns all writes of collected data. `web` is read-only against
  collected data and writes only admin tables (§13.8). Admin actions reach the collector
  through the database plus a `"channels:changed"` broadcast.
- **OTP:** every long-lived process is supervised; no bare `spawn`. Per-channel state
  lives in its `ChannelServer`; one failing channel must never affect another.
- **Collection never waits on Postgres:** every write of collected data from a
  collection process goes through the journal as a `Collector.Ops` operation (naming
  streams by `(channel, started_at)`), never straight to the Repo. New polled data is
  a new `Collector.Source`. Nothing in collection may crash the node (§10.1–10.3).
- **Pure core:** sessionizer, metrics, envelope decoding, signature verification and
  parsers are pure modules with no processes, database or network. GenServers only carry
  state and call them.
- **Migrations are expand-then-contract**: add first, remove only once no running code
  uses it; `collector` and `web` may run different versions for a while. Unique keys on
  hypertables include the time column. Continuous aggregates are expensive to change:
  design them carefully and say so when a change requires recreating one.

## 9. Frontend rules

- The server chooses resolution by range; **no series over ~2 000 points** reaches the
  browser (§13.4). Buckets carry avg and max; empty buckets are `null`, never 0.
- **History over cacheable JSON** (`/data/v1/...`), **only "now" over LiveView**. Chart
  data is never kept in LiveView assigns; it goes to the hook with `push_event`.
- One chart library (ECharts), one hook, a fixed set of chart kinds in `assets/js/charts/`.
  The server sends data and a kind, never ECharts options.
- Gaps are drawn as breaks with "no data" shading, never as zero or interpolated.
- All user-facing text through Gettext; layout with logical properties (`ms-`/`me-`,
  `start`/`end`) so right-to-left languages work later.
- Every public view is reproducible from its URL (period, channels, options in the query).

## 10. Tests

- **Tests are written with the feature or change, not afterwards.** A change is not done
  until its tests are in.
- Pure modules: unit tests, and property tests (StreamData) for anything that must survive
  random order, duplicates and gaps (sessionizer, metrics, chat windows).
- Parsers are tested against `fixtures/`.
- Pipeline pieces: integration tests against the simulator with real TimescaleDB and
  RabbitMQ in containers.
- A change to a metric or to the sessionizer includes a test showing the before and after
  on the same input.
- Before declaring work done, run the formatter and the full test suite, and report the
  real result, failures included.

## 11. Conventions

- **Never use real usernames or channel names** in docs, comments, code, tests, commit
  messages or examples. Use placeholders: `<channel>`, `<other-channel>`, `<slug>`,
  `<username>`, `<user id>`, or obviously fake values (`somestreamer`, `1234567`) where a
  test needs a concrete value. The same goes for anything else that identifies a real
  channel or person: real ids, stream titles, follower counts tied to a name. Real data
  lives only in `sim/recordings/` (git-ignored) and, anonymized, in `fixtures/`.
- Elixir: `mix format`; follow Phoenix and Ecto conventions; contexts own their schemas.
- Keep `project.md` accurate: when the implementation deliberately differs from it, update
  it in the same change (and log the decision, §3 above).
- Prefer the libraries already chosen (`project.md` §9) over adding new dependencies;
  adding one is a decision to log.
