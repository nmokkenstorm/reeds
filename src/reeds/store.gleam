import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import reeds/health.{
  type FeedHealth, type FeedOutcome, FeedHealth, Reached, Unreachable,
}
import reeds/whisper.{type Whisper, Whisper}
import sqlight.{type Connection, type Error}

/// `origin`/`origin_seq` identify the whisper's origin bridge and the seq
/// that bridge assigned it; `idem`, when present, collapses redundant
/// observations of the same underlying fact regardless of origin or timing.
/// Isolated from `schema` so a legacy-shape rebuild can recreate exactly this
/// table without repeating the column list.
const messages_ddl = "
create table if not exists messages(
  seq        integer primary key autoincrement,
  topic      text not null,
  ts         integer not null,
  sender     text not null,
  kind       text not null,
  body       text not null check (json_valid(body)),
  origin     text not null,
  origin_seq integer not null,
  idem       text,
  unique(origin, origin_seq)
) strict;
create index if not exists messages_topic on messages(topic);
create unique index if not exists messages_topic_idem
  on messages(topic, idem) where idem is not null;
"

const schema = messages_ddl
  <> "
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
create table if not exists cursors(
  peer   text primary key,
  cursor integer not null
) strict;
"

pub fn open(path: String, origin origin: String) -> Result(Connection, Error) {
  use conn <- result.try(sqlight.open(path))
  use _ <- result.try(sqlight.exec("pragma journal_mode = wal;", conn))
  use _ <- result.try(migrate(conn, origin))
  Ok(conn)
}

/// `create table if not exists` cannot widen a table that already exists in
/// the pre-mesh shape, and `strict` plus `not null` rule out a plain `alter
/// table add column` backfill. So: rebuild first when the legacy shape is
/// there, before `schema` runs its `messages_topic_idem` index against a
/// table that does not have an `idem` column yet. Every fresh database skips
/// the check and goes straight to `schema`.
fn migrate(conn: Connection, origin: String) -> Result(Nil, Error) {
  use exists <- result.try(has_messages_table(conn))
  use needs_backfill <- result.try(case exists {
    False -> Ok(False)
    True -> has_origin_column(conn) |> result.map(fn(has) { !has })
  })
  use _ <- result.try(case needs_backfill {
    True -> backfill_origin(conn, origin)
    False -> Ok(Nil)
  })
  sqlight.exec(schema, conn)
}

fn has_messages_table(conn: Connection) -> Result(Bool, Error) {
  sqlight.query(
    "select 1 from sqlite_master where type = 'table' and name = 'messages'",
    on: conn,
    with: [],
    expecting: decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

fn has_origin_column(conn: Connection) -> Result(Bool, Error) {
  sqlight.query(
    "select 1 from pragma_table_info('messages') where name = 'origin'",
    on: conn,
    with: [],
    expecting: decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(rows) { rows != [] })
}

/// Existing rows become home whispers of this bridge: `origin_seq = seq`,
/// same as a bridge that always assigned its own seq is its own origin_seq.
/// One transaction end to end, so a crash mid-rebuild leaves the original
/// table intact instead of a half-renamed mess.
fn backfill_origin(conn: Connection, origin: String) -> Result(Nil, Error) {
  use _ <- result.try(sqlight.exec("begin immediate;", conn))
  use _ <- result.try(sqlight.exec(
    "alter table messages rename to messages_v1;",
    conn,
  ))
  use _ <- result.try(sqlight.exec(messages_ddl, conn))
  use _ <- result.try(sqlight.query(
    "insert into messages(seq, topic, ts, sender, kind, body, origin, origin_seq, idem)
       select seq, topic, ts, sender, kind, body, ?1, seq, null from messages_v1",
    on: conn,
    with: [sqlight.text(origin)],
    expecting: decode.success(Nil),
  ))
  use _ <- result.try(sqlight.exec("drop table messages_v1;", conn))
  sqlight.exec("commit;", conn)
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

/// The outcome of a home publish: a fresh row with the `origin_seq` this
/// bridge assigned it, or the seq of the row already holding a duplicate
/// `(topic, idem)`. Kept distinct from a plain `Int` so callers know not to
/// fan out a dedup no-op as if it were a new event.
pub type Appended {
  Inserted(seq: Int, origin_seq: Int)
  Deduped(seq: Int)
}

/// Home publish: `origin` is always this bridge, and `origin_seq` is a
/// per-origin counter computed in the same insert, not tracked separately,
/// so publishing still costs one insert. A duplicate `(topic, idem)` is a
/// silent no-op that reports the seq of the row already holding it, so a
/// republished source fact looks identical to the caller whether or not
/// anything actually changed.
pub fn append(
  conn: Connection,
  topic topic: String,
  ts ts: Int,
  sender sender: String,
  kind kind: String,
  body body: String,
  origin origin: String,
  idem idem: Option(String),
) -> Result(Appended, String) {
  sqlight.query(
    "insert or ignore into messages(topic, ts, sender, kind, body, origin, origin_seq, idem)
     values (?1, ?2, ?3, ?4, ?5, ?6,
             (select coalesce(max(origin_seq), 0) + 1 from messages where origin = ?6),
             ?7)
     returning seq, origin_seq",
    on: conn,
    with: [
      sqlight.text(topic),
      sqlight.int(ts),
      sqlight.text(sender),
      sqlight.text(kind),
      sqlight.text(body),
      sqlight.text(origin),
      sqlight.nullable(sqlight.text, idem),
    ],
    expecting: {
      use seq <- decode.field(0, decode.int)
      use origin_seq <- decode.field(1, decode.int)
      decode.success(#(seq, origin_seq))
    },
  )
  |> result.map_error(describe)
  |> result.try(fn(rows) {
    case rows {
      [#(seq, origin_seq), ..] -> Ok(Inserted(seq:, origin_seq:))
      [] -> existing_seq(conn, topic, idem) |> result.map(Deduped)
    }
  })
}

/// Foreign ingest: `origin`/`origin_seq`/`idem` already belong to the whisper,
/// so unlike `append` they are preserved verbatim rather than computed; only
/// the local `seq` is this bridge's to assign. `None` on a dedup no-op rather
/// than an error, since a duplicate is expected traffic on every resumed
/// pull, not a fault.
pub fn append_foreign(
  conn: Connection,
  whisper: Whisper,
) -> Result(Option(Int), String) {
  sqlight.query(
    "insert or ignore into messages(topic, ts, sender, kind, body, origin, origin_seq, idem)
     values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     returning seq",
    on: conn,
    with: [
      sqlight.text(whisper.topic),
      sqlight.int(whisper.ts),
      sqlight.text(whisper.sender),
      sqlight.text(whisper.kind),
      sqlight.text(whisper.body),
      sqlight.text(whisper.origin),
      sqlight.int(whisper.origin_seq),
      sqlight.nullable(sqlight.text, whisper.idem),
    ],
    expecting: decode.field(0, decode.int, decode.success),
  )
  |> result.map_error(describe)
  |> result.map(fn(rows) {
    case rows {
      [seq, ..] -> Some(seq)
      [] -> None
    }
  })
}

fn existing_seq(
  conn: Connection,
  topic: String,
  idem: Option(String),
) -> Result(Int, String) {
  case idem {
    None -> Error("insert returned no seq")
    Some(idem) ->
      sqlight.query(
        "select seq from messages where topic = ?1 and idem = ?2",
        on: conn,
        with: [sqlight.text(topic), sqlight.text(idem)],
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
}

fn whisper_decoder() -> decode.Decoder(Whisper) {
  use seq <- decode.field(0, decode.int)
  use topic <- decode.field(1, decode.string)
  use ts <- decode.field(2, decode.int)
  use sender <- decode.field(3, decode.string)
  use kind <- decode.field(4, decode.string)
  use body <- decode.field(5, decode.string)
  use origin <- decode.field(6, decode.string)
  use origin_seq <- decode.field(7, decode.int)
  use idem <- decode.field(8, decode.optional(decode.string))
  decode.success(Whisper(
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

const select_whispers = "select seq, topic, ts, sender, kind, body, origin, origin_seq, idem from messages"

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
        select_whispers <> " where seq > ?1 order by seq asc limit ?2",
        on: conn,
        with: [sqlight.int(since), sqlight.int(limit)],
        expecting: whisper_decoder(),
      )
    _ ->
      sqlight.query(
        select_whispers
          <> " where (topic = ?1 or substr(topic, 1, length(?1) + 1) = ?1 || '.')
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

/// A peer never polled has cursor 0, same as `since=0` on the read API: the
/// pull loop's first tick asks for everything the peer has.
pub fn get_peer_cursor(conn: Connection, peer: String) -> Result(Int, Error) {
  sqlight.query(
    "select cursor from cursors where peer = ?1",
    on: conn,
    with: [sqlight.text(peer)],
    expecting: decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(rows) {
    case rows {
      [cursor, ..] -> cursor
      [] -> 0
    }
  })
}

pub fn put_peer_cursor(
  conn: Connection,
  peer: String,
  cursor: Int,
) -> Result(Nil, Error) {
  sqlight.query(
    "insert into cursors(peer, cursor) values (?1, ?2)
     on conflict(peer) do update set cursor = excluded.cursor",
    on: conn,
    with: [sqlight.text(peer), sqlight.int(cursor)],
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
