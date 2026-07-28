import gleam/json
import gleam/list
import gleam/string

pub type Whisper {
  Whisper(
    seq: Int,
    topic: String,
    ts: Int,
    sender: String,
    kind: String,
    body: String,
  )
}

/// Prefix matching is per dotted segment: "bb.pr" matches "bb.pr" and
/// "bb.pr.x" but not "bb.private". "*" matches every topic.
pub fn matches(topic topic: String, prefix prefix: String) -> Bool {
  prefix == "*" || topic == prefix || string.starts_with(topic, prefix <> ".")
}

pub fn valid_topic(topic: String) -> Bool {
  topic != ""
  && topic
  |> string.split(".")
  |> list.all(valid_segment)
}

const segment_chars = "abcdefghijklmnopqrstuvwxyz0123456789-_"

fn valid_segment(segment: String) -> Bool {
  segment != ""
  && segment
  |> string.to_graphemes
  |> list.all(string.contains(segment_chars, _))
}

/// body is already-validated JSON, so it is spliced in raw rather than
/// re-encoded, which would double-escape it.
pub fn to_json_string(whisper: Whisper) -> String {
  let head =
    json.object([
      #("seq", json.int(whisper.seq)),
      #("topic", json.string(whisper.topic)),
      #("ts", json.int(whisper.ts)),
      #("sender", json.string(whisper.sender)),
      #("kind", json.string(whisper.kind)),
    ])
    |> json.to_string
  string.drop_end(head, 1) <> ",\"body\":" <> whisper.body <> "}"
}

pub fn list_to_json_string(whispers: List(Whisper)) -> String {
  "[" <> whispers |> list.map(to_json_string) |> string.join(",") <> "]"
}
