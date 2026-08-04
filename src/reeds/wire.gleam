import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import reeds/whisper.{type Whisper, Whisper}

/// Parses a `/t/*?since=N` response (the pull loop's read of a peer, and the
/// replication format the whole mesh is built on) into its whispers and the
/// cursor to resume from. Each whisper's `body` is recovered as the exact
/// raw JSON text the origin bridge sent, never decoded and re-encoded:
/// `whisper.to_json_string` already avoids that round trip on the write
/// side (see its docstring) because re-serialising an arbitrary freeform
/// payload risks reordering keys or renumbering a JSON number; this is the
/// same discipline applied to reading.
pub fn parse_since_response(
  text: String,
) -> Result(#(List(Whisper), Int, Bool), String) {
  use next_since <- result.try(
    json.parse(
      from: text,
      using: decode.field("next_since", decode.int, decode.success),
    )
    |> result.replace_error("malformed response: missing next_since"),
  )
  use more <- result.try(
    json.parse(
      from: text,
      using: decode.field("more", decode.bool, decode.success),
    )
    |> result.replace_error("malformed response: missing more"),
  )
  use array_text <- result.try(whispers_array_text(text))
  use objects <- result.try(split_top_level(array_text))
  use whispers <- result.try(list.try_map(objects, parse_whisper))
  Ok(#(whispers, next_since, more))
}

/// `read_since`'s handler always writes `whispers` as the envelope's first
/// key, so its raw array text can be found by scanning straight past this
/// literal prefix rather than a general-purpose key lookup.
const whispers_marker = "{\"whispers\":["

fn whispers_array_text(text: String) -> Result(String, String) {
  case string.starts_with(text, whispers_marker) {
    False -> Error("malformed response: expected a whispers array first")
    True ->
      close_array(
        string.to_graphemes(string.drop_start(
          text,
          string.length(whispers_marker),
        )),
      )
  }
}

/// Finds the text up to (excluding) the array's own matching `]`, tracking
/// nested `{}`/`[]` and string escapes so a bracket inside a whisper's body
/// cannot be mistaken for the array's end.
fn close_array(chars: List(String)) -> Result(String, String) {
  scan(chars, Scan(depth: 0, in_string: False, escaped: False, current: []))
  |> result.map(fn(scan) { scan.current |> list.reverse |> string.concat })
}

type Scan {
  Scan(depth: Int, in_string: Bool, escaped: Bool, current: List(String))
}

fn scan(chars: List(String), acc: Scan) -> Result(Scan, String) {
  case chars {
    [] -> Error("malformed response: unterminated whispers array")
    [c, ..rest] ->
      case acc.in_string {
        True -> scan_in_string(c, rest, acc)
        False -> scan_out_string(c, rest, acc)
      }
  }
}

fn scan_in_string(
  c: String,
  rest: List(String),
  acc: Scan,
) -> Result(Scan, String) {
  let acc = Scan(..acc, current: [c, ..acc.current])
  case acc.escaped {
    True -> scan(rest, Scan(..acc, escaped: False))
    False ->
      case c {
        "\\" -> scan(rest, Scan(..acc, escaped: True))
        "\"" -> scan(rest, Scan(..acc, in_string: False))
        _ -> scan(rest, acc)
      }
  }
}

fn scan_out_string(
  c: String,
  rest: List(String),
  acc: Scan,
) -> Result(Scan, String) {
  case c {
    "]" if acc.depth == 0 -> Ok(acc)
    "\"" ->
      scan(rest, Scan(..acc, in_string: True, current: [c, ..acc.current]))
    "{" | "[" ->
      scan(rest, Scan(..acc, depth: acc.depth + 1, current: [c, ..acc.current]))
    "}" | "]" ->
      scan(rest, Scan(..acc, depth: acc.depth - 1, current: [c, ..acc.current]))
    _ -> scan(rest, Scan(..acc, current: [c, ..acc.current]))
  }
}

/// Splits a JSON array's inner text (no enclosing brackets) into each
/// top-level element's raw text, respecting nested `{}`/`[]` and string
/// escapes so nothing inside one whisper's body can be mistaken for a
/// sibling boundary.
fn split_top_level(inner: String) -> Result(List(String), String) {
  split(
    string.to_graphemes(inner),
    Split(depth: 0, in_string: False, escaped: False, current: [], elements: []),
  )
  |> result.map(fn(split) { push(split).elements |> list.reverse })
}

type Split {
  Split(
    depth: Int,
    in_string: Bool,
    escaped: Bool,
    current: List(String),
    elements: List(String),
  )
}

fn split(chars: List(String), acc: Split) -> Result(Split, String) {
  case chars {
    [] ->
      case acc.depth, acc.in_string {
        0, False -> Ok(acc)
        _, _ -> Error("malformed response: unterminated whisper object")
      }
    [c, ..rest] ->
      case acc.in_string {
        True -> split_in_string(c, rest, acc)
        False -> split_out_string(c, rest, acc)
      }
  }
}

fn split_in_string(
  c: String,
  rest: List(String),
  acc: Split,
) -> Result(Split, String) {
  let acc = Split(..acc, current: [c, ..acc.current])
  case acc.escaped {
    True -> split(rest, Split(..acc, escaped: False))
    False ->
      case c {
        "\\" -> split(rest, Split(..acc, escaped: True))
        "\"" -> split(rest, Split(..acc, in_string: False))
        _ -> split(rest, acc)
      }
  }
}

fn split_out_string(
  c: String,
  rest: List(String),
  acc: Split,
) -> Result(Split, String) {
  case c {
    "," if acc.depth == 0 -> split(rest, push(acc))
    "\"" ->
      split(rest, Split(..acc, in_string: True, current: [c, ..acc.current]))
    "{" | "[" ->
      split(
        rest,
        Split(..acc, depth: acc.depth + 1, current: [c, ..acc.current]),
      )
    "}" | "]" ->
      split(
        rest,
        Split(..acc, depth: acc.depth - 1, current: [c, ..acc.current]),
      )
    _ -> split(rest, Split(..acc, current: [c, ..acc.current]))
  }
}

fn push(acc: Split) -> Split {
  let text = acc.current |> list.reverse |> string.concat
  case text {
    "" -> Split(..acc, current: [])
    _ -> Split(..acc, current: [], elements: [text, ..acc.elements])
  }
}

fn parse_whisper(obj_text: String) -> Result(Whisper, String) {
  use body <- result.try(raw_body(obj_text))
  use fields <- result.try(
    json.parse(from: obj_text, using: whisper_fields_decoder())
    |> result.replace_error("malformed whisper fields"),
  )
  let #(seq, topic, ts, sender, kind, origin, origin_seq, idem) = fields
  Ok(Whisper(
    seq:,
    topic:,
    ts:,
    sender:,
    kind:,
    body:,
    origin:,
    origin_seq:,
    idem:,
  ))
}

fn whisper_fields_decoder() -> decode.Decoder(
  #(Int, String, Int, String, String, String, Int, Option(String)),
) {
  use seq <- decode.field("seq", decode.int)
  use topic <- decode.field("topic", decode.string)
  use ts <- decode.field("ts", decode.int)
  use sender <- decode.field("sender", decode.string)
  use kind <- decode.field("kind", decode.string)
  use origin <- decode.field("origin", decode.string)
  use origin_seq <- decode.field("origin_seq", decode.int)
  use idem <- decode.field("idem", decode.optional(decode.string))
  decode.success(#(seq, topic, ts, sender, kind, origin, origin_seq, idem))
}

/// `body` is always the last key `whisper.to_json_string` writes, so
/// everything from the marker to the object's own closing brace is exactly
/// its raw text, whatever that text contains.
fn raw_body(obj_text: String) -> Result(String, String) {
  case string.split_once(obj_text, "\"body\":") {
    Error(_) -> Error("malformed whisper object: missing body field")
    Ok(#(_before, after)) ->
      case string.ends_with(after, "}") {
        True -> Ok(string.drop_end(after, 1))
        False -> Error("malformed whisper object: missing closing brace")
      }
  }
}
