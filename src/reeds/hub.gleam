import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import reeds/clock
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
  GetSourceState(name: String, reply: Subject(Option(String)))
  PutSourceState(name: String, state: String)
}

type Sub {
  Sub(prefix: String, subject: Subject(Whisper), pid: Pid)
}

type State {
  State(conn: Connection, subs: List(Sub))
}

pub fn start(
  conn: Connection,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new(State(conn:, subs: []))
  |> actor.on_message(handle)
  |> actor.start
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
  }
}

fn publish(
  state: State,
  topic: String,
  sender: String,
  kind: String,
  body: String,
  reply: Subject(Result(Int, String)),
) -> actor.Next(State, Msg) {
  use <- require_valid_topic(state, topic, reply)
  let ts = clock.now_ms()
  case store.append(state.conn, topic:, ts:, sender:, kind:, body:) {
    Error(message) -> {
      process.send(reply, Error(message))
      actor.continue(state)
    }
    Ok(seq) -> {
      let live = list.filter(state.subs, fn(sub) { process.is_alive(sub.pid) })
      let published = whisper.Whisper(seq:, topic:, ts:, sender:, kind:, body:)
      live
      |> list.filter(fn(sub) { whisper.matches(topic, sub.prefix) })
      |> list.each(fn(sub) { process.send(sub.subject, published) })
      process.send(reply, Ok(seq))
      actor.continue(State(..state, subs: live))
    }
  }
}

/// Sources publish directly into the hub, bypassing the API's validation,
/// so the hub is the backstop that keeps malformed topics out of the log.
fn require_valid_topic(
  state: State,
  topic: String,
  reply: Subject(Result(Int, String)),
  continue: fn() -> actor.Next(State, Msg),
) -> actor.Next(State, Msg) {
  case whisper.valid_topic(topic) {
    True -> continue()
    False -> {
      process.send(reply, Error("invalid topic: " <> topic))
      actor.continue(state)
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
