# Mesh and state view

Status: draft spec, 2026-08-03. Covers the per-host bridge topology, peer
sync, auth, the materialized state view, and the whisper kind conventions
that make agent tasks foldable. Docker image, `REEDS_BIND`, and `REEDS_URL`
already exist and are assumed.

## Motivation

Whispering must never depend on the network. A pane publishing a finding
mid-task hits local SQLite and moves on; whether another machine hears about
it in 200ms or after the laptop wakes is the mesh's problem, not the agent's.
So: one bridge daemon per host, local agents keep talking to loopback
unchanged, and bridges sync with each other. The trust boundary moves to
bridge-to-bridge links: machines authenticate, panes stay frictionless.

Whispers are immutable appends, so the mesh state is a grow-only set. No
conflict resolution exists anywhere in this design; convergence is set union.

## Terms

- **bridge**: a reeds daemon participating in the mesh. Every daemon is one.
- **origin**: the bridge where a whisper was first published.
- **peer**: another bridge this one syncs with, from config.
- **home whisper**: origin is this bridge. **foreign whisper**: it is not.

## Origin tagging

Every whisper gains two columns:

- `origin` (text): the origin bridge's name, from config (`bridge.name`,
  default hostname). Stamped at publish time for home whispers; preserved
  verbatim on ingest of foreign ones.
- `origin_seq` (int): the seq assigned by the origin bridge.
- `idem` (text, nullable): source-derived idempotency fingerprint, see
  Source dedup below. Null for freeform whispers.

The local `seq` remains what consumers see: on ingest a bridge assigns the
foreign whisper the next local seq. The single-cursor consumer API survives
untouched; ordering is per-origin FIFO with arbitrary interleave, and display
ordering stays `ts`. Dedup: `UNIQUE(origin, origin_seq)` always, plus
`UNIQUE(topic, idem)` where `idem` is non-null. Inserting a duplicate on
either key is a silent no-op.

Migration: existing rows get `origin = <bridge.name>`, `origin_seq = seq`.

## Wire protocol

Sync reuses the existing read API. `GET /t/*?since=N` responses gain `origin`
and `origin_seq` per whisper (home whispers of the serving bridge report
themselves as origin). That response IS the replication format; there is no
second wire shape.

One new route for hosts that cannot be dialed (NAT):

- `POST /ingest`: body is the same shape as a `since` response's `whispers`
  array. The receiving bridge dedups on both unique keys and assigns
  local seqs. Returns `{"accepted": n, "cursors": {origin: max_origin_seq}}`
  so the pusher can advance without a read round-trip.

Loop prevention needs no hop counts: a bridge never forwards a whisper to a
peer that is its origin, and dedup catches everything else.

## Peer loops

Config per peer: `name`, `url`, `token`, `mode = pull | push | both`.

- **pull**: tail the peer's `/t/*?since=<cursor>` (or its SSE stream) and
  ingest. Cursor is the peer's local seq, persisted per peer in a `cursors`
  table. Resumable, idempotent, outbound-only.
- **push**: batch-post home-and-known whispers the peer has not confirmed,
  via `/ingest`, advancing on the returned cursors.

A NAT'd laptop runs `both` against a reachable peer; reachable peers run
`pull` against each other. The always-on bridge becomes a rendezvous point by
uptime, not by architecture. Backoff and health reporting reuse the source
machinery (`reeds.source.peer-<name>` transitions).

## Auth

Loopback requests stay unauthenticated. Any non-loopback request must carry
`Authorization: Bearer <token>` matching a configured peer token, or 401.
This lands in the same change that makes non-loopback bind useful; the README
already warns that widening the bind is deliberate. Per-sender tokens and
whisper signatures are explicitly deferred: senders remain self-asserted
within a trusted machine.

## Source dedup and ownership

Two bridges polling the same upstream would observe the same facts, but a
content hash cannot collapse them: diff-based pollers emit observer-local
transitions (a bridge that slept through `queued` emits `seen(completed)`
where its peer emitted `updated(completed)`), so bodies and kinds differ
per observer while the underlying fact is identical.

Instead each source computes an explicit `idem` fingerprint of the observed
fact, not of the observation: runs use `<run_id>:<state>:<result>`, PRs/MRs
use `<id>:<updated_on>`, health transitions use `<source>:<state>`. The
`UNIQUE(topic, idem)` key then collapses redundant observations regardless
of origin, kind, or timing; whichever observer lands first wins and the
surviving `kind` is theirs, which folds identically by topic either way.

With that, running a source on multiple bridges is redundancy, not
double-vision. Ownership remains the sensible default anyway: duplicate
pollers spend upstream rate limit for facts the mesh would discard. Put
upstream pollers (GitHub, GitLab) on the always-on bridge; keep
laptop-credential sources local; add a second poller only where missing a
window (laptop asleep, hub rebooting) actually hurts.

## State fold and dashboard

Topics are already primary keys (`gh.pr.infra.147`, `agents.roxanne.riot-315`).
Current state is a fold, in SQL, not in a page replaying 21k events:

- `GET /state?prefix=P`: for each topic under P, the latest whisper, minus
  topics whose latest kind is a tombstone (`pr.gone`, `mr.gone`, `done`).
  Each entry carries `topic`, `ts` (so the page renders ages), `sender`,
  `kind`, `body`, `origin`.

A static `/dashboard` page served by the daemon polls `/state`, groups by
topic prefix (host/org rollup), and shows last-seen ages on everything. The
page claims "last whispered", never "currently true": it is an event-sourced
view and wears that openly. Every bridge converges to the full log, so the
fold works on any of them; the phone view reads the always-on bridge.

## Kind conventions

Two kinds, so the fold can distinguish lanes without parsing bodies:

- `done`: terminal for its topic; the fold tombstones it.
- `needs-user`: the topic waits on a human; the dashboard surfaces these as
  a dedicated lane. Cleared by a later `status` or `done` on the same topic.

Agents that only ever emit `status` still fold correctly; they just never
leave the board except by staleness, which the ages make visible.

## Phases

1. **Origin tagging and idem.** Schema migration, stamp on publish, sources
   compute fingerprints, expose all three in reads. Done when: fresh and
   migrated databases serve `origin`/`origin_seq`/`idem` on every read
   route, publish still costs one insert, and re-publishing a source fact
   with the same `idem` no-ops.
2. **Bearer auth for non-loopback.** Done when: loopback works tokenless,
   non-loopback without a valid token is 401, and a peer token passes.
3. **Pull loop.** Peer config, cursors table, ingest with dedup. Done when:
   two daemons on one machine (different ports/dbs) converge, kill-and-resume
   loses nothing, and a whisper never round-trips back to its origin.
4. **Push mode and `/ingest`.** Done when: a `both`-mode bridge behind a
   one-way network boundary converges in both directions.
5. **State fold and dashboard.** `/state`, tombstones, the static page.
   Done when: the page renders live PR/CI/agent lanes with ages from a real
   log, and `pr.gone` topics are absent.
6. **Kind rollout.** `done`/`needs-user` documented in README and adopted by
   the agent-side conventions (global CLAUDE.md whisper guidance).

Deferred: mesh sizes beyond a handful of peers, per-sender auth, signatures,
retention/compaction policy for the append-only log.
