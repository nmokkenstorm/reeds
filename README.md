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

A source polls an upstream, diffs against its persisted fingerprint state,
and publishes the changes as whispers. Two providers ship today, both built
on the shared poller (`sources/poller.gleam`):

- `kind = "bitbucket"`: open PRs (`pr.seen` / `pr.updated` / `pr.gone` on
  `bb.pr.<repo>.<id>`) and recent pipeline runs (`pipe.seen` / `pipe.updated`
  on `bb.pipe.<repo>.<build>`). Needs `workspace`; `email` switches to Basic
  auth for Atlassian API tokens.
- `kind = "github"`: open PRs on `gh.pr.<repo>.<number>` and recent Actions
  runs (`run.seen` / `run.updated` on `gh.run.<repo>.<run_number>`). Needs
  `owner` and a PAT.

Sources are configured in `~/.config/reeds/config.toml` (override the path
with `REEDS_CONFIG`); each `[sources.<name>]` section is an independent
instance with its own diff state, sender name, and credentials:

```toml
port = 7333
db = "/absolute/path/reeds.db"

[sources.work]
kind = "bitbucket"
workspace = "acme"
repos = ["web", "api"]
interval_seconds = 30            # optional, default 30, minimum 5
token = "..."                    # or token_env = "VAR" to read from env
# email = "..."                  # set for Atlassian API tokens (Basic auth)
# topic_prefix = "bb"            # default ("gh" for github)

[sources.personal]
kind = "github"
owner = "someone"
repos = ["some-repo"]
token_env = "GITHUB_TOKEN"
```

`REEDS_DB` and `REEDS_PORT` env vars override the file's values. Config is
fail-fast: a malformed file, a wrong-typed value, or a section that fails
validation refuses the whole boot (comment a section out to disable it). A
daemon quietly running without a source you configured is the failure mode
this trades away. Fetch failures at runtime are whispered on
`reeds.source.<name>` with kind `error`, and a failed poll keeps the previous
diff baseline, so transient upstream errors do not fabricate `gone`/`seen`
storms.

Everything runs under one OTP supervision tree (one-for-one): the hub is a
named process, so a crashed hub restarts without invalidating the subject
that sources and the HTTP layer hold, and a crashed source restarts clean
and reloads its diff baseline on the next tick. One caveat: a hub restart
drops the in-memory subscriber list, so SSE clients see silence until they
reconnect; `since`-cursor pulls are unaffected. launchd remains the backstop
for whole-VM death.

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
