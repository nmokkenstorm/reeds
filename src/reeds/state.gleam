import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// One topic's latest whisper: the fold, not the log. `origin` is None on a
/// database that predates mesh sync, so the fold never blocks on it.
pub type Entry {
  Entry(
    topic: String,
    ts: Int,
    sender: String,
    kind: String,
    body: String,
    origin: Option(String),
  )
}

/// Kinds that retire a topic from the fold: the last word on it was that it
/// is over, so showing it as live state would be a lie.
const tombstones = ["pr.gone", "mr.gone", "done"]

pub fn is_tombstone(kind: String) -> Bool {
  list.contains(tombstones, kind)
}

/// body is already-validated JSON, so it is spliced in raw rather than
/// re-encoded, which would double-escape it.
pub fn to_json_string(entry: Entry) -> String {
  let head =
    json.object([
      #("topic", json.string(entry.topic)),
      #("ts", json.int(entry.ts)),
      #("sender", json.string(entry.sender)),
      #("kind", json.string(entry.kind)),
    ])
    |> json.to_string
  let base = string.drop_end(head, 1)
  let with_origin = case entry.origin {
    Some(origin) ->
      base <> ",\"origin\":" <> json.to_string(json.string(origin))
    None -> base
  }
  with_origin <> ",\"body\":" <> entry.body <> "}"
}

pub fn list_to_json_string(entries: List(Entry)) -> String {
  "[" <> entries |> list.map(to_json_string) |> string.join(",") <> "]"
}
