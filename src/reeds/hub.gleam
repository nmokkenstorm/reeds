import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import reeds/clock
import reeds/health
import reeds/state.{type Entry}
import reeds/store
import reeds/whisper.{type Whisper}
import sqlight.{type Connection}

const replay_batch = 500

pub type Msg {
  Publish(
    topic: String,
    sender: String,
    kind: String,
    body: String,
    reply: Subject(Result(Int, String)),
  )
  Subscribe(prefix: String, since: Int, subscriber: Subject(Whisper))
  ReadSince(
    prefix: String,
    since: Int,
    limit: Int,
    reply: Subject(Result(List(Whisper), String)),
  )
  /// The fold: latest whisper per topic under `prefix`, tombstoned topics
  /// dropped.
  ReadState(prefix: String, reply: Subject(Result(List(Entry), String)))
  GetSourceState(name: String, reply: Subject(Option(String)))
  PutSourceState(name: String, state: String)
  /// Record one poll's per-feed reachability and reply with the resulting
  /// all-feeds-failing streak, which the runner turns into a backoff.
  RecordPoll(name: String, feeds: List(health.FeedOutcome), reply: Subject(Int))
  Health(reply: Subject(Result(List(health.SourceHealth), String)))
  SetRoster(sources: List(health.Registration))
}

type Sub {
  Sub(prefix: String, subject: Subject(Whisper), pid: Pid)
}

type State {
  State(conn: Connection, subs: List(Sub), roster: List(health.Registration))
}

fn initial(conn: Connection) -> State {
  State(conn:, subs: [], roster: [])
}

pub fn start(
  conn: Connection,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new(initial(conn))
  |> actor.on_message(handle)
  |> actor.start
}

/// Supervised child spec under a registered name, so a restarted hub keeps
/// answering the same named subject that sources and the API hold.
pub fn supervised(
  conn: Connection,
  name: process.Name(Msg),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() {
    actor.new(initial(conn))
    |> actor.on_message(handle)
    |> actor.named(name)
    |> actor.start
  })
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Publish(topic, sender, kind, body, reply) ->
      publish(state, topic, sender, kind, body, reply)
    Subscribe(prefix, since, subscriber) ->
      subscribe(state, prefix, since, subscriber)
    ReadSince(prefix, since, limit, reply) -> {
      store.read_since(state.conn, prefix:, since:, limit:)
      |> result.map_error(store.describe)
      |> process.send(reply, _)
      actor.continue(state)
    }
    ReadState(prefix, reply) -> {
      let has_origin = store.has_origin_column(state.conn)
      store.read_state(state.conn, prefix:, has_origin:)
      |> result.map_error(store.describe)
      |> process.send(reply, _)
      actor.continue(state)
    }
    GetSourceState(name, reply) -> {
      store.get_source_state(state.conn, name)
      |> result.unwrap(option.None)
      |> process.send(reply, _)
      actor.continue(state)
    }
    PutSourceState(name, source_state) -> {
      let _ = store.put_source_state(state.conn, name, source_state)
      actor.continue(state)
    }
    RecordPoll(name, feeds, reply) -> record_poll(state, name, feeds, reply)
    Health(reply) -> {
      process.send(reply, report(state))
      actor.continue(state)
    }
    SetRoster(sources) -> {
      let _ =
        store.prune_sources(
          state.conn,
          list.map(sources, fn(source) { source.name }),
        )
      actor.continue(State(..state, roster: sources))
    }
  }
}

/// Health is written and its transition whisper emitted in the same actor
/// message, so the two cannot disagree about when a source broke.
fn record_poll(
  state: State,
  name: String,
  feeds: List(health.FeedOutcome),
  reply: Subject(Int),
) -> actor.Next(State, Msg) {
  let before = summarise(state, name)
  let now = clock.now_ms()
  let _ = store.record_poll(state.conn, name, feeds, now)
  let after = summarise(state, name)
  let streak =
    option.map(after, fn(health) { health.down_streak }) |> option.unwrap(0)
  let state = case after {
    None -> state
    Some(after) ->
      case health.announce(before, after, now) {
        None -> state
        Some(announcement) -> {
          let #(state, _) =
            emit(
              state,
              "reeds.source." <> name,
              name,
              announcement.kind,
              announcement.body,
            )
          state
        }
      }
  }
  process.send(reply, streak)
  actor.continue(state)
}

fn summarise(state: State, name: String) -> Option(health.SourceHealth) {
  case store.read_source_health(state.conn, name) {
    Error(_) -> None
    Ok([]) -> None
    Ok(feeds) -> Some(health.summarise(name, kind_of(state, name), True, feeds))
  }
}

fn kind_of(state: State, name: String) -> String {
  state.roster
  |> list.find(fn(source) { source.name == name })
  |> result.map(fn(source) { source.kind })
  |> result.unwrap("unknown")
}

/// Reported from the roster, not from whatever rows exist: a configured
/// source always appears, as `disabled` or `unknown` if it has never polled.
fn report(state: State) -> Result(List(health.SourceHealth), String) {
  store.read_health(state.conn)
  |> result.map_error(store.describe)
  |> result.map(fn(rows) {
    list.map(state.roster, fn(source) {
      let feeds =
        rows
        |> list.filter(fn(row) { row.0 == source.name })
        |> list.map(fn(row) { row.1 })
      health.summarise(source.name, source.kind, source.enabled, feeds)
    })
  })
}

fn publish(
  state: State,
  topic: String,
  sender: String,
  kind: String,
  body: String,
  reply: Subject(Result(Int, String)),
) -> actor.Next(State, Msg) {
  let #(state, result) = emit(state, topic, sender, kind, body)
  process.send(reply, result)
  actor.continue(state)
}

/// Append and fan out. Sources publish directly into the hub, bypassing the
/// API's validation, so this is the backstop that keeps malformed topics out
/// of the log.
fn emit(
  state: State,
  topic: String,
  sender: String,
  kind: String,
  body: String,
) -> #(State, Result(Int, String)) {
  case whisper.valid_topic(topic) {
    False -> #(state, Error("invalid topic: " <> topic))
    True -> {
      let ts = clock.now_ms()
      case store.append(state.conn, topic:, ts:, sender:, kind:, body:) {
        Error(message) -> #(state, Error(message))
        Ok(seq) -> {
          let live =
            list.filter(state.subs, fn(sub) { process.is_alive(sub.pid) })
          let published =
            whisper.Whisper(seq:, topic:, ts:, sender:, kind:, body:)
          live
          |> list.filter(fn(sub) { whisper.matches(topic, sub.prefix) })
          |> list.each(fn(sub) { process.send(sub.subject, published) })
          #(State(..state, subs: live), Ok(seq))
        }
      }
    }
  }
}

/// Replay runs inside the hub actor, so no concurrent publish can interleave
/// with catch-up: the subscriber sees a gapless, ordered stream.
fn subscribe(
  state: State,
  prefix: String,
  since: Int,
  subscriber: Subject(Whisper),
) -> actor.Next(State, Msg) {
  replay(state.conn, prefix, since, subscriber)
  case process.subject_owner(subscriber) {
    Error(_) -> actor.continue(state)
    Ok(pid) ->
      actor.continue(
        State(..state, subs: [
          Sub(prefix:, subject: subscriber, pid:),
          ..state.subs
        ]),
      )
  }
}

fn replay(
  conn: Connection,
  prefix: String,
  since: Int,
  subscriber: Subject(Whisper),
) -> Nil {
  case store.read_since(conn, prefix:, since:, limit: replay_batch) {
    Error(_) -> Nil
    Ok([]) -> Nil
    Ok(batch) -> {
      list.each(batch, fn(w) { process.send(subscriber, w) })
      case list.length(batch) < replay_batch {
        True -> Nil
        False -> {
          let assert Ok(last) = list.last(batch)
          replay(conn, prefix, last.seq, subscriber)
        }
      }
    }
  }
}
