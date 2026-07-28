import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import reeds/source.{type Draft, Draft}

/// A pre-rendered upstream record: stable id, change fingerprint, and the
/// whisper body it becomes when it is new or changed.
pub type Item {
  Item(id: String, fingerprint: String, body: String)
}

/// One polled collection within an upstream (PRs, pipeline runs). `ns` is
/// both the state-key namespace and the topic/kind segment. `track_gone`
/// whispers `<ns>.gone` when a previously seen item leaves the collection;
/// leave it off for windowed collections where ageing out is not an event.
pub type Feed {
  Feed(
    ns: String,
    track_gone: Bool,
    url: fn(String) -> String,
    decoder: fn(String) -> decode.Decoder(List(Item)),
  )
}

pub type Upstream {
  Upstream(
    name: String,
    prefix: String,
    repos: List(String),
    headers: List(#(String, String)),
    feeds: List(Feed),
  )
}

type Acc =
  #(Dict(String, String), List(Draft))

/// Poll every feed of every repo, diff against the persisted fingerprint
/// map, and return the new map plus drafts for what changed.
pub fn poll(
  up: Upstream,
  previous: Option(String),
) -> #(Option(String), List(Draft)) {
  let seen = parse_state(previous)
  let #(current, drafts) =
    up.repos
    |> list.fold(#(dict.new(), []), fn(acc, repo) {
      list.fold(up.feeds, acc, fn(acc, feed) {
        poll_feed(acc, up, repo, seen, feed)
      })
    })
  let gone_spaces =
    up.feeds
    |> list.filter(fn(feed) { feed.track_gone })
    |> list.map(fn(feed) { feed.ns <> ":" })
  let gone =
    seen
    |> dict.keys
    |> list.filter(fn(key) {
      list.any(gone_spaces, string.starts_with(key, _))
      && !dict.has_key(current, key)
    })
    |> list.map(gone_draft(up.prefix, _))
  #(Some(dump_state(current)), list.append(drafts, gone))
}

fn poll_feed(
  acc: Acc,
  up: Upstream,
  repo: String,
  seen: Dict(String, String),
  feed: Feed,
) -> Acc {
  let #(fingerprints, drafts) = acc
  case fetch(up.headers, feed.url(repo), feed.decoder(repo)) {
    // Carry the previous baseline forward on failure, so a transient error
    // neither fabricates gone events nor replays seen ones after recovery.
    Error(reason) -> #(carry_forward(fingerprints, seen, key_ns(feed, repo)), [
      error_draft(up.name, repo, reason),
      ..drafts
    ])
    Ok(items) -> {
      let fingerprints =
        list.fold(items, fingerprints, fn(fps, item) {
          dict.insert(fps, key(feed, repo, item), item.fingerprint)
        })
      let fresh =
        list.filter_map(items, fn(item) {
          case dict.get(seen, key(feed, repo, item)) {
            Error(_) -> Ok(draft(up.prefix, feed.ns, repo, item, "seen"))
            Ok(previous) if previous != item.fingerprint ->
              Ok(draft(up.prefix, feed.ns, repo, item, "updated"))
            Ok(_) -> Error(Nil)
          }
        })
      #(fingerprints, list.append(fresh, drafts))
    }
  }
}

fn key_ns(feed: Feed, repo: String) -> String {
  feed.ns <> ":" <> string.lowercase(repo) <> "/"
}

fn key(feed: Feed, repo: String, item: Item) -> String {
  key_ns(feed, repo) <> item.id
}

fn carry_forward(
  fingerprints: Dict(String, String),
  seen: Dict(String, String),
  ns: String,
) -> Dict(String, String) {
  dict.fold(seen, fingerprints, fn(fps, key, fingerprint) {
    case string.starts_with(key, ns) {
      True -> dict.insert(fps, key, fingerprint)
      False -> fps
    }
  })
}

fn draft(
  prefix: String,
  ns: String,
  repo: String,
  item: Item,
  verb: String,
) -> Draft {
  Draft(
    topic: prefix
      <> "."
      <> ns
      <> "."
      <> string.lowercase(repo)
      <> "."
      <> item.id,
    kind: ns <> "." <> verb,
    body: item.body,
  )
}

fn gone_draft(prefix: String, seen_key: String) -> Draft {
  let #(ns, repo, id) = case string.split(seen_key, ":") {
    [ns, rest] ->
      case string.split(rest, "/") {
        [repo, id] -> #(ns, repo, id)
        _ -> #(ns, "unknown", rest)
      }
    _ -> #("item", "unknown", seen_key)
  }
  Draft(
    topic: prefix <> "." <> ns <> "." <> repo <> "." <> id,
    kind: ns <> ".gone",
    body: json.to_string(
      json.object([#("repo", json.string(repo)), #("id", json.string(id))]),
    ),
  )
}

fn error_draft(name: String, repo: String, reason: String) -> Draft {
  Draft(
    topic: "reeds.source." <> name,
    kind: "error",
    body: json.to_string(
      json.object([
        #("repo", json.string(repo)),
        #("error", json.string(reason)),
      ]),
    ),
  )
}

fn fetch(
  headers: List(#(String, String)),
  url: String,
  decoder: decode.Decoder(List(Item)),
) -> Result(List(Item), String) {
  use req <- result.try(
    request.to(url) |> result.replace_error("bad url: " <> url),
  )
  let req =
    list.fold(headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  use resp <- result.try(
    httpc.send(req) |> result.replace_error("request failed: " <> url),
  )
  case resp.status {
    200 ->
      json.parse(from: resp.body, using: decoder)
      |> result.replace_error("unparseable response from " <> url)
    status -> Error("status " <> int.to_string(status) <> " from " <> url)
  }
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
