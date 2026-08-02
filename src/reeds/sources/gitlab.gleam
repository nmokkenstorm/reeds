import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import reeds/config
import reeds/source.{type Source, Source}
import reeds/sources/poller
import tom

/// Build a GitLab source from a `[sources.<name>]` config table. Watches
/// open merge requests (`mr.seen` / `mr.updated` / `mr.gone`) and recent
/// pipelines (`pipe.seen` / `pipe.updated`), default topic prefix `gl`.
/// `base_url` selects the instance (self-hosted or gitlab.com).
pub fn from_spec(
  name: String,
  table: Dict(String, tom.Toml),
) -> Result(Source, String) {
  let context = "source " <> name
  use base_url <- result.try(config.optional_string(
    table,
    "base_url",
    "https://gitlab.com",
    context,
  ))
  use group <- result.try(config.required_string(table, "group", context))
  use repos <- result.try(config.string_list(table, "repos", context))
  use token <- result.try(config.token(table, context))
  use interval_ms <- result.try(config.interval_ms(table, context))
  use prefix <- result.try(config.topic_prefix(table, "gl", context))
  let base = case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1)
    False -> base_url
  }
  // GitLab addresses projects by URL-encoded full path, slash included.
  let project = fn(repo) {
    base <> "/api/v4/projects/" <> uri.percent_encode(group <> "/" <> repo)
  }
  let upstream =
    poller.Upstream(
      name:,
      prefix:,
      repos:,
      headers: [
        #("authorization", "Bearer " <> token),
        #("accept", "application/json"),
      ],
      feeds: [
        poller.Feed(
          ns: "mr",
          track_gone: True,
          url: fn(repo) {
            project(repo) <> "/merge_requests?state=opened&per_page=50"
          },
          decoder: mrs_decoder,
        ),
        poller.Feed(
          ns: "pipe",
          track_gone: False,
          url: fn(repo) { project(repo) <> "/pipelines?per_page=15" },
          decoder: pipelines_decoder,
        ),
      ],
    )
  Ok(Source(name:, interval_ms:, poll: poller.poll(upstream, _)))
}

/// Decoder for GitLab's MR list (a bare array); exported for tests.
/// Identity is `iid`, the per-project MR number shown in the UI; `id` is
/// instance-global and useless for humans.
pub fn mrs_decoder(repo: String) -> decode.Decoder(List(poller.Item)) {
  decode.list(mr_decoder(repo))
}

fn mr_decoder(repo: String) -> decode.Decoder(poller.Item) {
  use iid <- decode.field("iid", decode.int)
  use title <- decode.field("title", decode.string)
  use state <- decode.field("state", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  decode.success(poller.Item(
    id: int.to_string(iid),
    fingerprint: state <> "|" <> updated_at,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("id", json.int(iid)),
        #("title", json.string(title)),
        #("state", json.string(state)),
        #("updated_on", json.string(updated_at)),
      ]),
    ),
  ))
}

/// Decoder for GitLab's pipeline list; exported for tests. A pipeline has a
/// single `status` covering both progress and outcome (running/success/
/// failed/...), so the fingerprint is just that.
pub fn pipelines_decoder(repo: String) -> decode.Decoder(List(poller.Item)) {
  decode.list(pipeline_decoder(repo))
}

fn pipeline_decoder(repo: String) -> decode.Decoder(poller.Item) {
  use id <- decode.field("id", decode.int)
  use status <- decode.field("status", decode.string)
  use ref <- decode.field("ref", decode.optional(decode.string))
  let ref = option.unwrap(ref, "")
  decode.success(poller.Item(
    id: int.to_string(id),
    fingerprint: status,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("pipeline", json.int(id)),
        #("state", json.string(status)),
        #("branch", json.string(ref)),
      ]),
    ),
  ))
}
