import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import reeds/config
import reeds/source.{type Source, Source}
import reeds/sources/poller
import tom

const api_base = "https://api.bitbucket.org/2.0/repositories"

/// Build a Bitbucket source from a `[sources.<name>]` config table. The
/// instance name becomes the whisper sender and the persisted-state key, so
/// two instances never share a diff baseline.
pub fn from_spec(
  name: String,
  table: Dict(String, tom.Toml),
) -> Result(Source, String) {
  let reader = config.source_reader(name, table)
  use workspace <- result.try(config.required_string(reader, "workspace"))
  use repos <- result.try(config.string_list(reader, "repos"))
  use token <- result.try(config.token(reader))
  use email <- result.try(config.maybe_string(reader, "email"))
  use interval_ms <- result.try(config.interval_ms(reader))
  use backoff_cap_ms <- result.try(config.backoff_cap_ms(reader, interval_ms))
  use prefix <- result.try(config.topic_prefix(reader, "bb"))
  let authorization = case email {
    Some(email) ->
      "Basic "
      <> bit_array.base64_encode(
        bit_array.from_string(email <> ":" <> token),
        True,
      )
    None -> "Bearer " <> token
  }
  let upstream =
    poller.Upstream(
      name:,
      prefix:,
      repos:,
      headers: [
        #("authorization", authorization),
        #("accept", "application/json"),
      ],
      feeds: [
        poller.Feed(
          ns: "pr",
          track_gone: True,
          url: fn(repo) {
            api_base
            <> "/"
            <> workspace
            <> "/"
            <> repo
            <> "/pullrequests?state=OPEN&pagelen=50"
          },
          decoder: prs_decoder,
        ),
        poller.Feed(
          ns: "pipe",
          track_gone: False,
          url: fn(repo) {
            api_base
            <> "/"
            <> workspace
            <> "/"
            <> repo
            <> "/pipelines/?sort=-created_on&pagelen=15"
          },
          decoder: pipelines_decoder,
        ),
      ],
    )
  Ok(
    Source(name:, interval_ms:, backoff_cap_ms:, poll: poller.poll(upstream, _)),
  )
}

/// Decoder for Bitbucket's paged PR list; exported for tests.
pub fn prs_decoder(repo: String) -> decode.Decoder(List(poller.Item)) {
  decode.field("values", decode.list(pr_decoder(repo)), decode.success)
}

fn pr_decoder(repo: String) -> decode.Decoder(poller.Item) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use state <- decode.field("state", decode.string)
  use updated_on <- decode.field("updated_on", decode.string)
  decode.success(poller.Item(
    id: int.to_string(id),
    fingerprint: state <> "|" <> updated_on,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("id", json.int(id)),
        #("title", json.string(title)),
        #("state", json.string(state)),
        #("updated_on", json.string(updated_on)),
      ]),
    ),
  ))
}

/// Decoder for Bitbucket's paged pipeline list; exported for tests.
/// `state.result.name` is absent until a run completes and `target.ref_name`
/// is absent for non-branch targets, hence the defaults.
pub fn pipelines_decoder(repo: String) -> decode.Decoder(List(poller.Item)) {
  decode.field("values", decode.list(pipeline_decoder(repo)), decode.success)
}

fn pipeline_decoder(repo: String) -> decode.Decoder(poller.Item) {
  use build <- decode.field("build_number", decode.int)
  use state <- decode.subfield(["state", "name"], decode.string)
  use result <- decode.then(decode.optionally_at(
    ["state", "result", "name"],
    "",
    decode.string,
  ))
  use branch <- decode.then(decode.optionally_at(
    ["target", "ref_name"],
    "",
    decode.string,
  ))
  decode.success(poller.Item(
    id: int.to_string(build),
    fingerprint: state <> "|" <> result,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("build", json.int(build)),
        #("state", json.string(state)),
        #("result", json.string(result)),
        #("branch", json.string(branch)),
      ]),
    ),
  ))
}
