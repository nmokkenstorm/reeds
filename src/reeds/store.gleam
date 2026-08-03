import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import reeds/health.{
  type FeedHealth, type FeedOutcome, FeedHealth, Reached, Unreachable,
}
import reeds/state.{type Entry, Entry}
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
create table if not exists source_health(
  source               text not null,
  feed                 text not null,
  last_ok_ts           integer,
  consecutive_failures integer not null default 0,
  last_error           text,
  last_error_ts        integer,
  primary key (source, feed)
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

/// True once mesh-core's origin-tagging migration has run. Read on every
/// fold rather than cached at open time, so a database migrated mid-process
/// (or a fresh one) is picked up without a restart.
pub fn has_origin_column(conn: Connection) -> Bool {
  sqlight.query(
    "select 1 from pragma_table_info('messages') where name = 'origin'",
    on: conn,
    with: [],
    expecting: decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
  |> result.unwrap(False)
}

fn entry_decoder(has_origin has_origin: Bool) -> decode.Decoder(Entry) {
  use topic <- decode.field(0, decode.string)
  use ts <- decode.field(1, decode.int)
  use sender <- decode.field(2, decode.string)
  use kind <- decode.field(3, decode.string)
  use body <- decode.field(4, decode.string)
  case has_origin {
    False ->
      decode.success(Entry(topic:, ts:, sender:, kind:, body:, origin: None))
    True -> {
      use origin <- decode.field(5, decode.optional(decode.string))
      decode.success(Entry(topic:, ts:, sender:, kind:, body:, origin:))
    }
  }
}

/// The state fold: latest whisper per topic under `prefix`, tombstoned
/// topics dropped. `has_origin` picks the column list so a database that
/// predates mesh-core's origin migration is never queried for a column it
/// does not have.
pub fn read_state(
  conn: Connection,
  prefix prefix: String,
  has_origin has_origin: Bool,
) -> Result(List(Entry), Error) {
  let cols = case has_origin {
    True -> "topic, ts, sender, kind, body, origin"
    False -> "topic, ts, sender, kind, body"
  }
  let decoder = entry_decoder(has_origin:)
  let rows = case prefix {
    "*" -> {
      let sql = "select " <> cols <> " from messages
         where seq in (select max(seq) from messages group by topic)
         order by topic asc"
      sqlight.query(sql, on: conn, with: [], expecting: decoder)
    }
    _ -> {
      let sql = "select " <> cols <> " from messages
         where seq in (
           select max(seq) from messages
           where (topic = ?1 or substr(topic, 1, length(?1) + 1) = ?1 || '.')
           group by topic
         )
         order by topic asc"
      sqlight.query(
        sql,
        on: conn,
        with: [sqlight.text(prefix)],
        expecting: decoder,
      )
    }
  }
  rows
  |> result.map(list.filter(_, fn(entry) { !state.is_tombstone(entry.kind) }))
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

/// Record one poll's reachability per feed and drop rows for feeds the source
/// no longer polls, so a shrunk `repos` list cannot leave a phantom feed down
/// forever.
pub fn record_poll(
  conn: Connection,
  source: String,
  outcomes: List(FeedOutcome),
  now_ms: Int,
) -> Result(Nil, Error) {
  use _ <- result.try(
    outcomes
    |> list.try_map(fn(outcome) { record_feed(conn, source, outcome, now_ms) }),
  )
  prune_feeds(conn, source, outcomes)
}

fn record_feed(
  conn: Connection,
  source: String,
  outcome: FeedOutcome,
  now_ms: Int,
) -> Result(Nil, Error) {
  case outcome {
    Reached(feed) ->
      sqlight.query(
        "insert into source_health(source, feed, last_ok_ts, consecutive_failures)
         values (?1, ?2, ?3, 0)
         on conflict(source, feed) do update set
           last_ok_ts = excluded.last_ok_ts,
           consecutive_failures = 0,
           last_error = null,
           last_error_ts = null",
        on: conn,
        with: [sqlight.text(source), sqlight.text(feed), sqlight.int(now_ms)],
        expecting: decode.success(Nil),
      )
      |> result.replace(Nil)
    Unreachable(feed, reason) ->
      sqlight.query(
        "insert into source_health(source, feed, consecutive_failures, last_error, last_error_ts)
         values (?1, ?2, 1, ?3, ?4)
         on conflict(source, feed) do update set
           consecutive_failures = source_health.consecutive_failures + 1,
           last_error = excluded.last_error,
           last_error_ts = excluded.last_error_ts",
        on: conn,
        with: [
          sqlight.text(source),
          sqlight.text(feed),
          sqlight.text(reason),
          sqlight.int(now_ms),
        ],
        expecting: decode.success(Nil),
      )
      |> result.replace(Nil)
  }
}

fn prune_feeds(
  conn: Connection,
  source: String,
  outcomes: List(FeedOutcome),
) -> Result(Nil, Error) {
  let keep =
    outcomes
    |> list.map(fn(outcome) {
      case outcome {
        Reached(feed) -> feed
        Unreachable(feed, _) -> feed
      }
    })
    |> json.array(json.string)
    |> json.to_string
  sqlight.query(
    "delete from source_health
     where source = ?1 and feed not in (select value from json_each(?2))",
    on: conn,
    with: [sqlight.text(source), sqlight.text(keep)],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

fn feed_health_decoder() -> decode.Decoder(#(String, FeedHealth)) {
  use source <- decode.field(0, decode.string)
  use feed <- decode.field(1, decode.string)
  use last_ok_ts <- decode.field(2, decode.optional(decode.int))
  use consecutive_failures <- decode.field(3, decode.int)
  use last_error <- decode.field(4, decode.optional(decode.string))
  use last_error_ts <- decode.field(5, decode.optional(decode.int))
  decode.success(#(
    source,
    FeedHealth(
      feed:,
      last_ok_ts:,
      consecutive_failures:,
      last_error:,
      last_error_ts:,
    ),
  ))
}

pub fn read_health(
  conn: Connection,
) -> Result(List(#(String, FeedHealth)), Error) {
  sqlight.query(
    "select source, feed, last_ok_ts, consecutive_failures, last_error,
            last_error_ts
     from source_health order by source asc, feed asc",
    on: conn,
    with: [],
    expecting: feed_health_decoder(),
  )
}

pub fn read_source_health(
  conn: Connection,
  source: String,
) -> Result(List(FeedHealth), Error) {
  sqlight.query(
    "select source, feed, last_ok_ts, consecutive_failures, last_error,
            last_error_ts
     from source_health where source = ?1 order by feed asc",
    on: conn,
    with: [sqlight.text(source)],
    expecting: feed_health_decoder(),
  )
  |> result.map(list.map(_, fn(row) { row.1 }))
}

/// Drop health for sources no longer in the config, so a renamed or deleted
/// section does not haunt `/health`.
pub fn prune_sources(
  conn: Connection,
  names: List(String),
) -> Result(Nil, Error) {
  sqlight.query(
    "delete from source_health
     where source not in (select value from json_each(?1))",
    on: conn,
    with: [sqlight.text(json.to_string(json.array(names, json.string)))],
    expecting: decode.success(Nil),
  )
  |> result.replace(Nil)
}

pub fn describe(error: Error) -> String {
  let sqlight.SqlightError(_, message, _) = error
  message
}
