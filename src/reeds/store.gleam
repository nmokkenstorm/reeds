import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import reeds/whisper.{type Whisper, Whisper}
import sqlight.{type Connection, type Error}

const schema = "
create table if not exists messages(
  seq    integer primary key autoincrement,
  topic  text not null,
  ts     integer not null,
  sender text not null,
  kind   text not null,
  body   text not null check (json_valid(body))
) strict;
create index if not exists messages_topic on messages(topic);
create table if not exists source_state(
  name  text primary key,
  state text not null
) strict;
"

pub fn open(path: String) -> Result(Connection, Error) {
  use conn <- result.try(sqlight.open(path))
  use _ <- result.try(sqlight.exec("pragma journal_mode = wal;", conn))
  use _ <- result.try(sqlight.exec(schema, conn))
  Ok(conn)
}

pub fn version(conn: Connection) -> String {
  sqlight.query(
    "select sqlite_version()",
    on: conn,
    with: [],
    expecting: decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) {
    case rows {
      [version, ..] -> version
      [] -> "unknown"
    }
  })
  |> result.unwrap("unknown")
}

pub fn append(
  conn: Connection,
  topic topic: String,
  ts ts: Int,
  sender sender: String,
  kind kind: String,
  body body: String,
) -> Result(Int, String) {
  sqlight.query(
    "insert into messages(topic, ts, sender, kind, body)
     values (?1, ?2, ?3, ?4, ?5) returning seq",
    on: conn,
    with: [
      sqlight.text(topic),
      sqlight.int(ts),
      sqlight.text(sender),
      sqlight.text(kind),
      sqlight.text(body),
    ],
    expecting: decode.field(0, decode.int, decode.success),
  )
  |> result.map_error(describe)
  |> result.try(fn(rows) {
    case rows {
      [seq, ..] -> Ok(seq)
      [] -> Error("insert returned no seq")
    }
  })
}

fn whisper_decoder() -> decode.Decoder(Whisper) {
  use seq <- decode.field(0, decode.int)
  use topic <- decode.field(1, decode.string)
  use ts <- decode.field(2, decode.int)
  use sender <- decode.field(3, decode.string)
  use kind <- decode.field(4, decode.string)
  use body <- decode.field(5, decode.string)
  decode.success(Whisper(seq:, topic:, ts:, sender:, kind:, body:))
}

/// substr comparison instead of LIKE so prefixes containing % or _ cannot
/// widen the match.
pub fn read_since(
  conn: Connection,
  prefix prefix: String,
  since since: Int,
  limit limit: Int,
) -> Result(List(Whisper), Error) {
  case prefix {
    "*" ->
      sqlight.query(
        "select seq, topic, ts, sender, kind, body from messages
         where seq > ?1 order by seq asc limit ?2",
        on: conn,
        with: [sqlight.int(since), sqlight.int(limit)],
        expecting: whisper_decoder(),
      )
    _ ->
      sqlight.query(
        "select seq, topic, ts, sender, kind, body from messages
         where (topic = ?1 or substr(topic, 1, length(?1) + 1) = ?1 || '.')
           and seq > ?2
         order by seq asc limit ?3",
        on: conn,
        with: [sqlight.text(prefix), sqlight.int(since), sqlight.int(limit)],
        expecting: whisper_decoder(),
      )
  }
}

pub fn get_source_state(
  conn: Connection,
  name: String,
) -> Result(Option(String), Error) {
  sqlight.query(
    "select state from source_state where name = ?1",
    on: conn,
    with: [sqlight.text(name)],
    expecting: decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) {
    case rows {
      [state, ..] -> Some(state)
      [] -> None
    }
  })
}

pub fn put_source_state(
  conn: Connection,
  name: String,
  state: String,
) -> Result(Nil, Error) {
  sqlight.query(
    "insert into source_state(name, state) values (?1, ?2)
     on conflict(name) do update set state = excluded.state",
    on: conn,
    with: [sqlight.text(name), sqlight.text(state)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

pub fn describe(error: Error) -> String {
  let sqlight.SqlightError(_, message, _) = error
  message
}
