# reeds

Persistent whisper network for local agents. One Gleam daemon: dotted topics,
an append-only SQLite log, live SSE fan-out, cursor-based catch-up, and
pluggable poll-and-diff sources for external state (Bitbucket PRs to start).

Named for the reeds that whispered King Midas's secret.

## Run

```sh
gleam run
```

Env: `REEDS_PORT` (default 7333), `REEDS_DB` (default `reeds.db`).

## HTTP API

| Route                    | Effect                                                   |
| ------------------------ | -------------------------------------------------------- |
| `POST /t/:topic`         | Publish JSON body. Returns `{"seq": n}`.                 |
| `GET /t/:prefix?since=N` | Whispers after seq N under prefix. Returns `next_since`. |
| `GET /t/:prefix/events`  | SSE tail; `?since=N` or `Last-Event-ID` to resume.       |
| `GET /health`            | `{"ok":true}`                                            |

Headers on publish: `x-reeds-sender`, `x-reeds-kind` (both optional).

Topics are dotted lowercase segments (`bb.pr.api.12`). A prefix matches
whole segments: `bb.pr` matches `bb.pr.x` but not `bb.private`. `*` matches
everything. The sequence is global across topics, so one cursor works for any
prefix.

## CLI

```sh
bin/reeds pub agents.review.api '{"verdict":"carry on"}' review.done
bin/reeds since agents 0
bin/reeds tail            # firehose
bin/reeds-watch           # refreshing table for a tmux status pane
```

Env: `REEDS_URL`, `REEDS_SENDER`. `reeds-watch [prefix] [lines]` polls with a
cursor and shows `[live]`/`[down]`.

## Daemon

`launchd/dev.mokkenstorm.reeds.plist` keeps the daemon running (`KeepAlive`,
`RunAtLoad`, logs to `~/Library/Logs/reeds.log`):

```sh
cp launchd/dev.mokkenstorm.reeds.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist
launchctl kickstart -k gui/$(id -u)/dev.mokkenstorm.reeds   # restart
```

## Sources

A source polls an upstream, diffs against its persisted state, and publishes
the changes as whispers. The Bitbucket source watches open PRs (`pr.seen`,
`pr.updated`, `pr.gone` on `bb.pr.<repo>.<id>`) and recent pipeline runs
(`pipe.seen`, `pipe.updated` on `bb.pipe.<repo>.<build>`; the body carries
state, result, and branch). Configure via env, or `~/.config/reeds/env` when
running under the launchd agent:

```sh
BITBUCKET_WORKSPACE=...            # workspace slug
BITBUCKET_REPOS=slug-a,slug-b
BITBUCKET_TOKEN=...                # workspace/repo access token (Bearer)
BITBUCKET_EMAIL=...                # set only for Atlassian API tokens (Basic)
```

Fetch failures are whispered on `reeds.source.bitbucket` with kind `error`.

New providers implement `source.Source` (a name, an interval, and a
`poll: fn(Option(String)) -> #(Option(String), List(Draft))`) and register in
`reeds.gleam`.

## Design notes

- All writes and subscription attach go through one hub actor, so SSE replay
  and live delivery cannot interleave: streams are gapless and ordered.
- SQLite runs STRICT tables with a `json_valid` check; malformed whispers are
  rejected at the door, not discovered during decode.
- Source state (the diff baseline) persists in the same database, so a daemon
  restart does not refire old events.
