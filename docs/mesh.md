# Mesh and state view

Status: implemented as of 2026-08-04. Covers the
per-host bridge topology, peer sync, auth, the materialized state view, and
the whisper kind conventions that make agent tasks foldable.

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

Every whisper carries two mesh columns plus a fingerprint:

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
either key is a silent no-op reporting the existing seq.

A database from before origin tagging is migrated at open: existing rows are
backfilled with `origin = <bridge.name>`, `origin_seq = seq`, in one
transaction, rather than refusing to open.

## Wire protocol

Sync reuses the existing read API. `GET /t/*?since=N` responses carry
`origin`, `origin_seq`, and `idem` per whisper (home whispers of the serving
bridge report themselves as origin). That response IS the replication format;
there is no second wire shape.

One route exists for hosts that cannot be dialed (NAT):

- `POST /ingest`: body is a `GET /t/*?since=N` response verbatim, envelope
  included; a pusher forwards its own read without reshaping it, and the
  receiver ignores the pusher's `next_since`/`more` bookkeeping. The
  receiving bridge dedups on both unique keys and assigns local seqs.
  Returns `{"accepted": n, "cursors": {origin: max_origin_seq}}` so the
  pusher can advance without a read round-trip; a dedup no-op still advances
  the cursor, since a duplicate confirms receipt.

Loop prevention needs no hop counts: dedup on `(origin, origin_seq)` catches
any whisper that round-trips back to a bridge that already has it.

## Peer loops

Config per peer: `name`, `url`, `token`, `mode = pull | push | both`, plus
the same `interval_seconds`/`backoff_cap_seconds` knobs sources take.

- **pull**: tail the peer's `/t/*?since=<cursor>` and ingest. The cursor is
  the peer's local seq, persisted per peer, so kill-and-resume loses
  nothing. Outbound-only, resumable, idempotent.
- **push**: batch everything past a persisted outbound cursor to the peer's
  `/ingest`, in the read API's response shape, and advance on success. An
  empty batch still posts, so reachability stays an honest health signal;
  echoes the peer already holds are no-ops under its dedup.

A NAT'd laptop runs `both` against a reachable peer; reachable peers run
`pull` against each other. The always-on bridge becomes a rendezvous point
by uptime, not by architecture. One actor per peer runs both directions in
one tick and reports them as feeds of one health source, so `degraded`
means "one direction failing"; peers report as `peer-<name>` in `/health`
and whisper transitions on `reeds.source.peer-<name>`, backing off only
when every direction is down.

## Auth

Loopback requests stay unauthenticated. Any non-loopback request must carry
`Authorization: Bearer <token>` matching a configured peer token, or the
daemon answers 401 before routing. Per-sender tokens and whisper signatures
are explicitly deferred: senders remain self-asserted within a trusted
machine. Tokens can live in a separate 0600 file via config imports, see
[sources.md](sources.md).

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

The static `/dashboard` page served by the daemon polls `/state`, groups by
topic prefix (host/org rollup), and shows last-seen ages on everything;
`needs-user` whispers get a dedicated lane. The page claims "last
whispered", never "currently true": it is an event-sourced view and wears
that openly. Every bridge converges to the full log, so the fold works on
any of them; the phone view reads the always-on bridge.

## Kind conventions

Two kinds, so the fold can distinguish lanes without parsing bodies:

- `done`: terminal for its topic; the fold tombstones it.
- `needs-user`: the topic waits on a human; the dashboard surfaces these as
  a dedicated lane. Cleared by a later `status` or `done` on the same topic.

Agents that only ever emit `status` still fold correctly; they just never
leave the board except by staleness, which the ages make visible.

## Deferred

Unchanged from the original spec: mesh sizes beyond a handful of peers,
per-sender auth, signatures, retention/compaction policy for the
append-only log.
