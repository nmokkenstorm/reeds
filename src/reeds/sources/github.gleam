import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option
import gleam/result
import reeds/config
import reeds/source.{type Source, Source}
import reeds/sources/poller
import tom

const api_base = "https://api.github.com/repos"

/// Build a GitHub source from a `[sources.<name>]` config table. Watches
/// open PRs (`pr.seen` / `pr.updated` / `pr.gone`) and recent Actions runs
/// (`run.seen` / `run.updated`), default topic prefix `gh`.
pub fn from_spec(
  name: String,
  table: Dict(String, tom.Toml),
) -> Result(Source, String) {
  let context = "source " <> name
  use owner <- result.try(config.required_string(table, "owner", context))
  use repos <- result.try(config.string_list(table, "repos", context))
  use token <- result.try(config.token(table, context))
  use interval_ms <- result.try(config.interval_ms(table, context))
  use prefix <- result.try(config.topic_prefix(table, "gh", context))
  let upstream =
    poller.Upstream(
      name:,
      prefix:,
      repos:,
      headers: [
        #("authorization", "Bearer " <> token),
        #("accept", "application/vnd.github+json"),
        #("x-github-api-version", "2022-11-28"),
        #("user-agent", "reeds"),
      ],
      feeds: [
        poller.Feed(
          ns: "pr",
          track_gone: True,
          url: fn(repo) {
            api_base
            <> "/"
            <> owner
            <> "/"
            <> repo
            <> "/pulls?state=open&per_page=50"
          },
          decoder: prs_decoder,
        ),
        poller.Feed(
          ns: "run",
          track_gone: False,
          url: fn(repo) {
            api_base
            <> "/"
            <> owner
            <> "/"
            <> repo
            <> "/actions/runs?per_page=15"
          },
          decoder: runs_decoder,
        ),
      ],
    )
  Ok(Source(name:, interval_ms:, poll: poller.poll(upstream, _)))
}

/// Decoder for GitHub's PR list (a bare array, unlike Bitbucket's paging
/// envelope); exported for tests.
pub fn prs_decoder(repo: String) -> decode.Decoder(List(poller.Item)) {
  decode.list(pr_decoder(repo))
}

fn pr_decoder(repo: String) -> decode.Decoder(poller.Item) {
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", decode.string)
  use state <- decode.field("state", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  decode.success(poller.Item(
    id: int.to_string(number),
    fingerprint: state <> "|" <> updated_at,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("number", json.int(number)),
        #("title", json.string(title)),
        #("state", json.string(state)),
        #("updated_on", json.string(updated_at)),
      ]),
    ),
  ))
}

/// Decoder for GitHub's Actions run list; exported for tests.
/// `conclusion` and `head_branch` are JSON null until known. Identity is the
/// globally unique run `id`: `run_number` counts per workflow, so two
/// workflows in one repo can share a number.
pub fn runs_decoder(repo: String) -> decode.Decoder(List(poller.Item)) {
  decode.field("workflow_runs", decode.list(run_decoder(repo)), decode.success)
}

fn run_decoder(repo: String) -> decode.Decoder(poller.Item) {
  use id <- decode.field("id", decode.int)
  use run <- decode.field("run_number", decode.int)
  use workflow <- decode.field("name", decode.string)
  use status <- decode.field("status", decode.string)
  use conclusion <- decode.field("conclusion", decode.optional(decode.string))
  use branch <- decode.field("head_branch", decode.optional(decode.string))
  let conclusion = option.unwrap(conclusion, "")
  decode.success(poller.Item(
    id: int.to_string(id),
    fingerprint: status <> "|" <> conclusion,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("run", json.int(run)),
        #("workflow", json.string(workflow)),
        #("state", json.string(status)),
        #("result", json.string(conclusion)),
        #("branch", json.string(option.unwrap(branch, ""))),
      ]),
    ),
  ))
}
