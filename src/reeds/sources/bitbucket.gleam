import envoy
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import reeds/source.{type Source, Draft, Source}

const api_base = "https://api.bitbucket.org/2.0/repositories"

type Auth {
  Bearer(token: String)
  Basic(email: String, token: String)
}

type Config {
  Config(workspace: String, repos: List(String), auth: Auth)
}

pub type Pr {
  Pr(id: Int, title: String, state: String, updated_on: String)
}

pub type Pipeline {
  Pipeline(build: Int, state: String, result: String, branch: String)
}

pub fn from_env() -> Option(Source) {
  let config = {
    use workspace <- result.try(env("BITBUCKET_WORKSPACE"))
    use repos <- result.try(env("BITBUCKET_REPOS"))
    use token <- result.try(env("BITBUCKET_TOKEN"))
    let auth = case env("BITBUCKET_EMAIL") {
      Ok(email) -> Basic(email:, token:)
      Error(_) -> Bearer(token:)
    }
    Ok(Config(
      workspace:,
      repos: repos |> string.split(",") |> list.map(string.trim),
      auth:,
    ))
  }
  case config {
    Error(_) -> None
    Ok(config) ->
      Some(
        Source(name: "bitbucket", interval_ms: 30_000, poll: fn(previous) {
          poll(config, previous)
        }),
      )
  }
}

fn env(name: String) -> Result(String, Nil) {
  case envoy.get(name) {
    Ok("") -> Error(Nil)
    other -> result.replace_error(other, Nil)
  }
}

/// State is a fingerprint map keyed "pr:repo/id" and "pipe:repo/build".
/// A PR vanishing from the OPEN list only tells us it is gone, not why,
/// hence the single "pr.gone" kind. Pipelines age out of the recent window
/// silently; their terminal state was already whispered.
fn poll(
  config: Config,
  previous: Option(String),
) -> #(Option(String), List(source.Draft)) {
  let seen = parse_state(previous)
  let #(current, drafts) =
    config.repos
    |> list.fold(#(dict.new(), []), fn(acc, repo) {
      acc
      |> poll_prs(config, repo, seen)
      |> poll_pipelines(config, repo, seen)
    })
  let gone =
    seen
    |> dict.keys
    |> list.filter(fn(k) {
      string.starts_with(k, "pr:") && !dict.has_key(current, k)
    })
    |> list.map(gone_draft)
  #(Some(dump_state(current)), list.append(drafts, gone))
}

type Acc =
  #(Dict(String, String), List(source.Draft))

fn poll_prs(
  acc: Acc,
  config: Config,
  repo: String,
  seen: Dict(String, String),
) -> Acc {
  let #(fingerprints, drafts) = acc
  case
    fetch(config, repo, "/pullrequests?state=OPEN&pagelen=50", prs_decoder())
  {
    Error(reason) -> #(fingerprints, [error_draft(repo, reason), ..drafts])
    Ok(prs) -> {
      let fingerprints =
        list.fold(prs, fingerprints, fn(fps, pr) {
          dict.insert(fps, pr_key(repo, pr.id), pr_fingerprint(pr))
        })
      let fresh =
        list.filter_map(prs, fn(pr) {
          case changed(seen, pr_key(repo, pr.id), pr_fingerprint(pr)) {
            New -> Ok(pr_draft(repo, pr, "pr.seen"))
            Changed -> Ok(pr_draft(repo, pr, "pr.updated"))
            Same -> Error(Nil)
          }
        })
      #(fingerprints, list.append(fresh, drafts))
    }
  }
}

fn poll_pipelines(
  acc: Acc,
  config: Config,
  repo: String,
  seen: Dict(String, String),
) -> Acc {
  let #(fingerprints, drafts) = acc
  case
    fetch(
      config,
      repo,
      "/pipelines/?sort=-created_on&pagelen=15",
      pipelines_decoder(),
    )
  {
    Error(reason) -> #(fingerprints, [error_draft(repo, reason), ..drafts])
    Ok(pipelines) -> {
      let fingerprints =
        list.fold(pipelines, fingerprints, fn(fps, pipe) {
          dict.insert(fps, pipe_key(repo, pipe.build), pipe_fingerprint(pipe))
        })
      let fresh =
        list.filter_map(pipelines, fn(pipe) {
          case
            changed(seen, pipe_key(repo, pipe.build), pipe_fingerprint(pipe))
          {
            New -> Ok(pipe_draft(repo, pipe, "pipe.seen"))
            Changed -> Ok(pipe_draft(repo, pipe, "pipe.updated"))
            Same -> Error(Nil)
          }
        })
      #(fingerprints, list.append(fresh, drafts))
    }
  }
}

type Change {
  New
  Changed
  Same
}

fn changed(
  seen: Dict(String, String),
  key: String,
  fingerprint: String,
) -> Change {
  case dict.get(seen, key) {
    Error(_) -> New
    Ok(previous) ->
      case previous == fingerprint {
        True -> Same
        False -> Changed
      }
  }
}

fn fetch(
  config: Config,
  repo: String,
  path: String,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  let url = api_base <> "/" <> config.workspace <> "/" <> repo <> path
  use req <- result.try(
    request.to(url) |> result.replace_error("bad url: " <> url),
  )
  let req =
    request.set_header(req, "authorization", auth_header(config.auth))
    |> request.set_header("accept", "application/json")
  use resp <- result.try(
    httpc.send(req) |> result.replace_error("request failed: " <> url),
  )
  case resp.status {
    200 ->
      json.parse(from: resp.body, using: decoder)
      |> result.replace_error("unparseable response from " <> repo <> path)
    status ->
      Error("status " <> int.to_string(status) <> " from " <> repo <> path)
  }
}

fn auth_header(auth: Auth) -> String {
  case auth {
    Bearer(token) -> "Bearer " <> token
    Basic(email, token) ->
      "Basic "
      <> bit_array.base64_encode(
        bit_array.from_string(email <> ":" <> token),
        True,
      )
  }
}

/// Decoder for Bitbucket's paged PR list; exported for tests.
pub fn prs_decoder() -> decode.Decoder(List(Pr)) {
  decode.field("values", decode.list(pr_decoder()), decode.success)
}

fn pr_decoder() -> decode.Decoder(Pr) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use state <- decode.field("state", decode.string)
  use updated_on <- decode.field("updated_on", decode.string)
  decode.success(Pr(id:, title:, state:, updated_on:))
}

/// Decoder for Bitbucket's paged pipeline list; exported for tests.
/// `state.result.name` is absent until a run completes and `target.ref_name`
/// is absent for non-branch targets, hence the defaults.
pub fn pipelines_decoder() -> decode.Decoder(List(Pipeline)) {
  decode.field("values", decode.list(pipeline_decoder()), decode.success)
}

fn pipeline_decoder() -> decode.Decoder(Pipeline) {
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
  decode.success(Pipeline(build:, state:, result:, branch:))
}

fn pr_key(repo: String, id: Int) -> String {
  "pr:" <> repo <> "/" <> int.to_string(id)
}

fn pipe_key(repo: String, build: Int) -> String {
  "pipe:" <> repo <> "/" <> int.to_string(build)
}

fn pr_fingerprint(pr: Pr) -> String {
  pr.state <> "|" <> pr.updated_on
}

fn pipe_fingerprint(pipe: Pipeline) -> String {
  pipe.state <> "|" <> pipe.result
}

fn pr_draft(repo: String, pr: Pr, kind: String) -> source.Draft {
  Draft(
    topic: "bb.pr." <> repo <> "." <> int.to_string(pr.id),
    kind:,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("id", json.int(pr.id)),
        #("title", json.string(pr.title)),
        #("state", json.string(pr.state)),
        #("updated_on", json.string(pr.updated_on)),
      ]),
    ),
  )
}

fn pipe_draft(repo: String, pipe: Pipeline, kind: String) -> source.Draft {
  Draft(
    topic: "bb.pipe." <> repo <> "." <> int.to_string(pipe.build),
    kind:,
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("build", json.int(pipe.build)),
        #("state", json.string(pipe.state)),
        #("result", json.string(pipe.result)),
        #("branch", json.string(pipe.branch)),
      ]),
    ),
  )
}

fn gone_draft(seen_key: String) -> source.Draft {
  let #(repo, id) = case seen_key |> string.drop_start(3) |> string.split("/") {
    [repo, id] -> #(repo, id)
    _ -> #("unknown", seen_key)
  }
  Draft(
    topic: "bb.pr." <> repo <> "." <> id,
    kind: "pr.gone",
    body: json.to_string(
      json.object([#("repo", json.string(repo)), #("id", json.string(id))]),
    ),
  )
}

fn error_draft(repo: String, reason: String) -> source.Draft {
  Draft(
    topic: "reeds.source.bitbucket",
    kind: "error",
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("error", json.string(reason)),
      ]),
    ),
  )
}

fn parse_state(previous: Option(String)) -> Dict(String, String) {
  previous
  |> option.map(fn(raw) {
    json.parse(from: raw, using: decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  })
  |> option.unwrap(dict.new())
}

fn dump_state(fingerprints: Dict(String, String)) -> String {
  fingerprints
  |> dict.to_list
  |> list.map(fn(entry) { #(entry.0, json.string(entry.1)) })
  |> json.object
  |> json.to_string
}
