# Sources

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

## Configuration

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

## Splitting secrets out

`import = ["tokens.toml"]` at the top of the config deep-merges the listed
files into it before validation. The intended split: everything structural
stays in `config.toml`, and a 0600 `tokens.toml` carries only credential
fragments:

```toml
# tokens.toml
[sources.work]
token = "..."

[peers.homelab]
token = "..."
```

Merging is additive only. A leaf key defined in more than one file refuses
the boot naming the key (`'sources.work.token' is already defined`), because
which file wins is exactly the ambiguity fail-fast config exists to rule
out. Imports do not nest, so the config graph is always one file plus its
listed fragments. Relative import paths resolve against the importing file's
directory and `~/` expands, so the config directory can move as a unit. A
named import that is missing or malformed also refuses the boot: a daemon
that quietly ran every source without credentials would be the worse
failure.

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

## New providers

New providers implement `source.Source` (a name, an interval, a backoff cap,
and a `poll: fn(Option(String)) -> Poll`) and register in `reeds.gleam`. The
returned `Poll` carries the next diff baseline, the drafts to publish, and a
`FeedOutcome` per polled collection. Reachability is a separate channel from
the drafts on purpose: when failure is just another draft, the runner cannot
tell a working poll from a broken one, so it can neither back off nor report
health.
