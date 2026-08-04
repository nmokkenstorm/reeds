# reeds

Persistent whisper network for local agents. One Gleam daemon: dotted topics,
an append-only SQLite log, live SSE fan-out, cursor-based catch-up, and
pluggable poll-and-diff sources for external state (Bitbucket, GitHub, GitLab).

Named for the reeds that whispered King Midas's secret.

## Install

Needs Erlang/OTP 29 and Gleam 1.17 to build. Nothing but Erlang to run.

From a checkout:

```sh
gleam run                                  # dev: rebuilds on every start
gleam export erlang-shipment               # or build a standalone release
./build/erlang-shipment/entrypoint.sh run  # ~3.4M, no Gleam toolchain needed
```

Put the CLI on your PATH:

```sh
ln -s "$PWD/bin/reeds" "$PWD/bin/reeds-watch" ~/.local/bin/
```

Env overrides, each taking precedence over the config file: `REEDS_PORT`
(default 7333), `REEDS_BIND` (default `localhost`), `REEDS_DB` (default
`reeds.db`), `REEDS_CONFIG` (default `~/.config/reeds/config.toml`).

`REEDS_BIND` defaults to loopback deliberately. Loopback requests are always
unauthenticated, so widening the bind is a decision you make on purpose, not
one a default makes for you: anything reaching the port from off-box needs a
peer token once you do.

## HTTP API

| Route                    | Effect                                                                                                                                               |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /t/:topic`         | Publish JSON body. Returns `{"seq": n}`.                                                                                                             |
| `GET /t/:prefix?since=N` | Whispers after seq N under prefix. Returns `next_since`.                                                                                             |
| `GET /t/:prefix/events`  | SSE tail; `?since=N` or `Last-Event-ID` to resume.                                                                                                   |
| `POST /ingest`           | Peer push: body is a `GET /t/*?since=N` response. Same wire shape, no second format. Returns `{"accepted": n, "cursors": {origin: max_origin_seq}}`. |
| `GET /health`            | Per-source health. `ok` is false when any source is down.                                                                                            |
| `GET /state?prefix=P`    | Latest whisper per topic under `P`, tombstones dropped.                                                                                              |
| `GET /dashboard`         | Static page that polls `/state` and renders it.                                                                                                      |

Headers on publish: `x-reeds-sender`, `x-reeds-kind` (both optional).

`/state` folds the log rather than replaying it: one entry per topic, the
latest whisper only, minus topics whose latest kind is `pr.gone`, `mr.gone`,
or `done`. It is honest about being event-sourced: an entry means "this was
last whispered", not "this is currently true". `/dashboard` groups entries by
topic prefix and shows ages; `needs-user` whispers get a dedicated lane.

### Auth

Loopback requests need nothing. Any other request must carry
`Authorization: Bearer <token>` matching a `[peers.<name>]` token from
config, or the daemon answers 401 before routing. Tokens are self-asserted
per bridge, not per sender: see `config.example.toml`.

Topics are dotted lowercase segments (`bb.pr.api.12`). A prefix matches
whole segments: `bb.pr` matches `bb.pr.x` but not `bb.private`. `*` matches
everything. The sequence is global across topics, so one cursor works for any
prefix.

## CLI

```sh
bin/reeds pub agents.review.api '{"verdict":"carry on"}' review.done
bin/reeds since agents 0
bin/reeds tail            # firehose
bin/reeds health          # per-source table; --json for the raw body
bin/reeds-watch           # refreshing table for a tmux status pane
```

Env: `REEDS_URL`, `REEDS_SENDER`. `reeds-watch [prefix] [lines]` polls with a
cursor and shows `[live]`/`[down]`. `reeds health` exits 1 when any source is
down, so it works as a real check rather than a liveness ping.

## Docs

- [docs/daemon.md](docs/daemon.md): running under launchd, systemd, or Docker
- [docs/sources.md](docs/sources.md): poll sources, config, health, backoff, new providers
- [docs/mesh.md](docs/mesh.md): mesh topology and state view spec
- [docs/design.md](docs/design.md): design notes and supervision
