import envoy
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

type Config {
  Config(workspace: String, repos: List(String), token: String)
}

type Pr {
  Pr(id: Int, title: String, state: String, updated_on: String)
}

pub fn from_env() -> Option(Source) {
  let config = {
    use workspace <- result.try(envoy.get("BITBUCKET_WORKSPACE"))
    use repos <- result.try(envoy.get("BITBUCKET_REPOS"))
    use token <- result.try(envoy.get("BITBUCKET_TOKEN"))
    Ok(Config(
      workspace:,
      repos: repos |> string.split(",") |> list.map(string.trim),
      token:,
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

/// State is a fingerprint map keyed "repo/id"; a PR vanishing from the OPEN
/// list only tells us it is gone, not why, hence the single "pr.gone" kind.
fn poll(
  config: Config,
  previous: Option(String),
) -> #(Option(String), List(source.Draft)) {
  let seen = parse_state(previous)
  let #(current, drafts) =
    config.repos
    |> list.fold(#(dict.new(), []), fn(acc, repo) {
      let #(fingerprints, drafts) = acc
      case fetch_open_prs(config, repo) {
        Error(reason) -> #(fingerprints, [error_draft(repo, reason), ..drafts])
        Ok(prs) -> {
          let with_repo =
            list.fold(prs, fingerprints, fn(fps, pr) {
              dict.insert(fps, key(repo, pr.id), fingerprint(pr))
            })
          #(with_repo, list.append(diff(repo, seen, prs), drafts))
        }
      }
    })
  let gone =
    seen
    |> dict.keys
    |> list.filter(fn(k) { !dict.has_key(current, k) })
    |> list.map(gone_draft)
  #(Some(dump_state(current)), list.append(drafts, gone))
}

fn diff(
  repo: String,
  seen: Dict(String, String),
  prs: List(Pr),
) -> List(source.Draft) {
  prs
  |> list.filter_map(fn(pr) {
    case dict.get(seen, key(repo, pr.id)) {
      Error(_) -> Ok(pr_draft(repo, pr, "pr.seen"))
      Ok(previous) ->
        case previous == fingerprint(pr) {
          True -> Error(Nil)
          False -> Ok(pr_draft(repo, pr, "pr.updated"))
        }
    }
  })
}

fn fetch_open_prs(config: Config, repo: String) -> Result(List(Pr), String) {
  let url =
    api_base
    <> "/"
    <> config.workspace
    <> "/"
    <> repo
    <> "/pullrequests?state=OPEN&pagelen=50"
  use req <- result.try(
    request.to(url) |> result.replace_error("bad url: " <> url),
  )
  let req =
    request.set_header(req, "authorization", "Bearer " <> config.token)
    |> request.set_header("accept", "application/json")
  use resp <- result.try(
    httpc.send(req) |> result.replace_error("request failed: " <> url),
  )
  case resp.status {
    200 ->
      json.parse(from: resp.body, using: response_decoder())
      |> result.replace_error("unparseable response from " <> repo)
    status -> Error("status " <> int.to_string(status) <> " from " <> repo)
  }
}

fn response_decoder() -> decode.Decoder(List(Pr)) {
  decode.field("values", decode.list(pr_decoder()), decode.success)
}

fn pr_decoder() -> decode.Decoder(Pr) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use state <- decode.field("state", decode.string)
  use updated_on <- decode.field("updated_on", decode.string)
  decode.success(Pr(id:, title:, state:, updated_on:))
}

fn key(repo: String, id: Int) -> String {
  repo <> "/" <> int.to_string(id)
}

fn fingerprint(pr: Pr) -> String {
  pr.state <> "|" <> pr.updated_on
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

fn gone_draft(seen_key: String) -> source.Draft {
  let #(repo, id) = case string.split(seen_key, "/") {
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
