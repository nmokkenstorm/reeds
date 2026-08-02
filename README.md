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

| Route                    | Effect                                                    |
| ------------------------ | --------------------------------------------------------- |
| `POST /t/:topic`         | Publish JSON body. Returns `{"seq": n}`.                  |
| `GET /t/:prefix?since=N` | Whispers after seq N under prefix. Returns `next_since`.  |
| `GET /t/:prefix/events`  | SSE tail; `?since=N` or `Last-Event-ID` to resume.        |
| `GET /health`            | Per-source health. `ok` is false when any source is down. |

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
bin/reeds health          # per-source table; --json for the raw body
bin/reeds-watch           # refreshing table for a tmux status pane
```

Env: `REEDS_URL`, `REEDS_SENDER`. `reeds-watch [prefix] [lines]` polls with a
cursor and shows `[live]`/`[down]`. `reeds health` exits 1 when any source is
down, so it works as a real check rather than a liveness ping.

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
and publishes the changes as whispers. Three providers ship today, all built
on the shared poller (`sources/poller.gleam`):

- `kind = "bitbucket"`: open PRs (`pr.seen` / `pr.updated` / `pr.gone` on
  `bb.pr.<repo>.<id>`) and recent pipeline runs (`pipe.seen` / `pipe.updated`
  on `bb.pipe.<repo>.<build>`). Needs `workspace`; `email` switches to Basic
  auth for Atlassian API tokens.
- `kind = "github"`: open PRs on `gh.pr.<repo>.<number>` and recent Actions
  runs (`run.seen` / `run.updated` on `gh.run.<repo>.<run_number>`). Needs
  `owner` and a PAT.
- `kind = "gitlab"`: open MRs on `gl.mr.<repo>.<iid>` and recent pipelines on
  `gl.pipe.<repo>.<id>`. Needs `group` and a token; `base_url` points at a
  self-hosted instance (default `https://gitlab.com`).

Sources are configured in `~/.config/reeds/config.toml` (override the path
with `REEDS_CONFIG`); `config.example.toml` is a tracked starting point, and a
`config.toml` in the repo root is gitignored so a real one cannot be committed.
Each `[sources.<name>]` section is an independent instance with its own diff
state, sender name, and credentials:

```toml
port = 7333
db = "/absolute/path/reeds.db"

[sources.work]
kind = "bitbucket"
workspace = "acme"
repos = ["web", "api"]
enabled = true                   # optional, default true; false parks the source
interval_seconds = 30            # optional, default 30, minimum 5
backoff_cap_seconds = 900        # optional, default 900; backoff ceiling while down
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
validation refuses the whole boot. A daemon quietly running without a source
you configured is the failure mode this trades away, so `enabled = false` is
the way to park one: it skips validation as well as polling, so stale
credentials cannot block a boot, and it prints a `disabled` line at startup.
A failed poll keeps the previous diff baseline, so transient upstream errors
do not fabricate `gone`/`seen` storms.

## Health

Each poll reports per-feed reachability, where a feed is one polled collection
of one repo (`pr:web`). Per feed rather than per repo, because a repo
with Actions disabled 404s its runs feed forever while its PRs feed is fine,
and that difference is the diagnosis. Source state is derived from the feed
rows, never stored alongside them:

| State      | Meaning                        | Backs off |
| ---------- | ------------------------------ | --------- |
| `healthy`  | every feed reached upstream    | no        |
| `degraded` | some feeds failing, not all    | no        |
| `down`     | every feed failed              | yes       |
| `disabled` | `enabled = false`              | n/a       |
| `unknown`  | configured, has not yet polled | n/a       |

Only a fully-down source backs off, doubling from `interval_seconds` up to
`backoff_cap_seconds` (default 900, and rejected below the interval). One
flaky feed must not slow down the healthy ones, which is why `degraded` keeps
the base interval.

Failures are whispered on `reeds.source.<name>` as `source.down`,
`source.degraded`, and `source.recovered`, and **only when the state or the
reason changes**. A source that 401s every 30 seconds for two days produces
one whisper, not 2,941 of them; `GET /health` answers "is it still broken".
A changed reason (401 to 403) counts as news and is whispered again.

`/health` reports the configured roster rather than whatever rows happen to
exist, so a source can no more go missing from the report than it can from
the boot.

Everything runs under one OTP supervision tree (one-for-one): the hub is a
named process, so a crashed hub restarts without invalidating the subject
that sources and the HTTP layer hold, and a crashed source restarts clean
and reloads its diff baseline on the next tick. One caveat: a hub restart
drops the in-memory subscriber list, so SSE clients see silence until they
reconnect; `since`-cursor pulls are unaffected. launchd remains the backstop
for whole-VM death.

New providers implement `source.Source` (a name, an interval, a backoff cap,
and a `poll: fn(Option(String)) -> Poll`) and register in `reeds.gleam`. The
returned `Poll` carries the next diff baseline, the drafts to publish, and a
`FeedOutcome` per polled collection. Reachability is a separate channel from
the drafts on purpose: when failure is just another draft, the runner cannot
tell a working poll from a broken one, so it can neither back off nor report
health.

## Design notes

- All writes and subscription attach go through one hub actor, so SSE replay
  and live delivery cannot interleave: streams are gapless and ordered.
- SQLite runs STRICT tables with a `json_valid` check; malformed whispers are
  rejected at the door, not discovered during decode.
- Source state (the diff baseline) persists in the same database, so a daemon
  restart does not refire old events.
- Health is written and its transition whisper emitted in the same hub message,
  so the two cannot disagree about when a source broke. Backoff lives in the
  source runner, with the rest of the scheduling.
