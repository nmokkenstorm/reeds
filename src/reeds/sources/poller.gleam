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
import reeds/health.{type FeedOutcome, Reached, Unreachable}
import reeds/source.{type Draft, type Poll, Draft, Poll}

/// gleam_httpc raises on transport errors it does not recognise instead of
/// returning them; catching here keeps a dropped keep-alive from killing the
/// polling actor.
@external(erlang, "reeds_rescue_ffi", "rescue")
fn rescue(thunk: fn() -> a) -> Result(a, String)

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
  #(Dict(String, String), List(Draft), List(FeedOutcome))

/// Poll every feed of every repo, diff against the persisted fingerprint
/// map, and return the new map, drafts for what changed, and whether each
/// feed was reachable.
pub fn poll(up: Upstream, previous: Option(String)) -> Poll {
  let seen = parse_state(previous)
  let #(current, drafts, outcomes) =
    up.repos
    |> list.fold(#(dict.new(), [], []), fn(acc, repo) {
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
  Poll(
    baseline: Some(dump_state(current)),
    drafts: list.append(drafts, gone),
    feeds: outcomes,
  )
}

fn poll_feed(
  acc: Acc,
  up: Upstream,
  repo: String,
  seen: Dict(String, String),
  feed: Feed,
) -> Acc {
  let #(fingerprints, drafts, outcomes) = acc
  case fetch(up.headers, feed.url(repo), feed.decoder(repo)) {
    // Carry the previous baseline forward on failure, so a transient error
    // neither fabricates gone events nor replays seen ones after recovery.
    Error(reason) -> #(
      carry_forward(fingerprints, seen, key_ns(feed, repo)),
      drafts,
      [Unreachable(feed: feed_key(feed, repo), reason:), ..outcomes],
    )
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
      #(fingerprints, list.append(fresh, drafts), [
        Reached(feed: feed_key(feed, repo)),
        ..outcomes
      ])
    }
  }
}

/// The health key for one polled collection; `key_ns` extends it into the
/// diff-state key space, so the two cannot drift apart.
fn feed_key(feed: Feed, repo: String) -> String {
  feed.ns <> ":" <> string.lowercase(repo)
}

fn key_ns(feed: Feed, repo: String) -> String {
  feed_key(feed, repo) <> "/"
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
  use resp <- result.try(case rescue(fn() { httpc.send(req) }) {
    Ok(sent) -> sent |> result.replace_error("request failed: " <> url)
    Error(crash) -> Error("transport error " <> crash <> " for " <> url)
  })
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
