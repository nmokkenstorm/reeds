import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import reeds/config.{type PeerSpec}
import reeds/health
import reeds/hub
import reeds/sources/poller
import reeds/whisper.{type Whisper}
import reeds/wire

/// gleam_httpc raises on transport errors it does not recognise instead of
/// returning them; catching here keeps a dropped keep-alive from killing the
/// peer loop actor.
@external(erlang, "reeds_rescue_ffi", "rescue")
fn rescue(thunk: fn() -> a) -> Result(a, String)

pub opaque type Msg {
  Tick
}

type State {
  State(peer: PeerSpec, hub: Subject(hub.Msg), self: Subject(Msg))
}

/// The `reeds.source.<name>` health/backoff machinery is keyed by name, so a
/// peer gets its own namespace within it rather than colliding with an
/// upstream source that happens to share the peer's config key.
fn health_name(peer: PeerSpec) -> String {
  "peer-" <> peer.name
}

/// Supervised child spec: a crashed peer loop restarts clean and resumes
/// each direction from whatever cursor it last persisted.
pub fn supervised(
  peer: PeerSpec,
  hub: Subject(hub.Msg),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(peer, hub) })
}

pub fn start(
  peer: PeerSpec,
  hub: Subject(hub.Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Tick)
    State(peer:, hub:, self:)
    |> actor.initialised
    |> actor.selecting(process.new_selector() |> process.select(self))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

/// One tick runs every direction the mode asks for and reports them as
/// feeds of one health source, in one `RecordPoll`: recording per direction
/// would prune the other direction's row, and one shared source is also
/// what makes `degraded` mean "one direction failing", which is the
/// diagnosis. Backoff only engages when every direction is down, same as
/// sources.
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Tick = msg
  let peer = state.peer
  let outcomes =
    list.append(
      case peer.mode {
        config.Push -> []
        _ -> [run_pull(state)]
      },
      case peer.mode {
        config.Pull -> []
        _ -> [run_push(state)]
      },
    )
  let down_streak = record_poll(state, outcomes)
  process.send_after(
    state.self,
    health.backoff(peer.interval_ms, down_streak, peer.backoff_cap_ms),
    Tick,
  )
  actor.continue(state)
}

fn run_pull(state: State) -> health.FeedOutcome {
  let peer = state.peer
  let cursor =
    process.call(state.hub, waiting: 5000, sending: hub.GetPeerCursor(
      peer.name,
      _,
    ))
  case pull(peer, cursor) {
    Error(reason) -> {
      io.println("reeds: peer " <> peer.name <> " pull failed: " <> reason)
      health.Unreachable("pull", reason)
    }
    Ok(#(whispers, next_cursor)) -> {
      ingest(state, whispers)
      process.send(state.hub, hub.PutPeerCursor(peer.name, next_cursor))
      health.Reached("pull")
    }
  }
}

fn run_push(state: State) -> health.FeedOutcome {
  let peer = state.peer
  let cursor =
    process.call(state.hub, waiting: 5000, sending: hub.GetPeerCursor(
      push_cursor_key(peer),
      _,
    ))
  let batch =
    process.call(state.hub, waiting: 5000, sending: hub.ReadSince(
      "*",
      cursor,
      push_batch,
      _,
    ))
  case batch |> result.try(push(peer, _, cursor)) {
    Error(reason) -> {
      io.println("reeds: peer " <> peer.name <> " push failed: " <> reason)
      health.Unreachable("push", reason)
    }
    Ok(next_cursor) -> {
      process.send(state.hub, hub.PutPeerCursor(
        push_cursor_key(peer),
        next_cursor,
      ))
      health.Reached("push")
    }
  }
}

/// Outbound cursor, in the same `cursors` table as the pull cursor: the
/// `:` keeps the keyspaces apart, since a peer name can never contain one.
fn push_cursor_key(peer: PeerSpec) -> String {
  "push:" <> peer.name
}

/// Empty batches are the common case (nothing new since last cursor) and are
/// skipped rather than round-tripping the hub for no reason.
fn ingest(state: State, whispers: List(Whisper)) -> Nil {
  case whispers {
    [] -> Nil
    _ ->
      case
        process.call(state.hub, waiting: 5000, sending: hub.IngestForeign(
          whispers,
          _,
        ))
      {
        Ok(_) -> Nil
        Error(reason) ->
          io.println(
            "reeds: peer " <> state.peer.name <> " ingest failed: " <> reason,
          )
      }
  }
}

fn record_poll(state: State, outcomes: List(health.FeedOutcome)) -> Int {
  process.call(state.hub, waiting: 5000, sending: hub.RecordPoll(
    health_name(state.peer),
    outcomes,
    _,
  ))
}

/// Mirrors the pull side's one-page-per-tick policy; the receiver ignores
/// the pushed envelope's `more`, the next tick drains the rest.
const push_batch = 500

/// POSTs one batch to the peer's `/ingest` and returns the local seq to
/// resume from. Sent verbatim in the read API's response shape, envelope
/// included. An empty batch still posts: reachability is the push feed's
/// health signal, and nothing-to-send must not mask a dead peer. Echoes
/// (whispers the peer itself originated) are pushed too; its dedup no-ops
/// them, which costs less than learning every peer's bridge name.
fn push(
  peer: PeerSpec,
  whispers: List(Whisper),
  cursor: Int,
) -> Result(Int, String) {
  let next_cursor =
    list.fold(whispers, cursor, fn(acc, w) { int.max(acc, w.seq) })
  let url = peer.url <> "/ingest"
  use req <- result.try(
    request.to(url) |> result.replace_error("bad peer url: " <> url),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> peer.token)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(wire.since_response(
      whispers,
      next_since: next_cursor,
      more: list.length(whispers) == push_batch,
    ))
  use resp <- result.try(case rescue(fn() { httpc.send(req) }) {
    Ok(sent) ->
      sent
      |> result.map_error(fn(e) { poller.describe_error(e) <> " for " <> url })
    Error(crash) -> Error("transport error " <> crash <> " for " <> url)
  })
  case resp.status {
    200 -> Ok(next_cursor)
    status -> Error("status " <> int.to_string(status) <> " from " <> url)
  }
}

/// One page of the peer's `/t/*` read API, resumed from `cursor`. `more`
/// (another page already waiting) is not chased within one tick: the next
/// scheduled tick picks it up, which keeps one slow peer from starving
/// every other source and peer this actor's poll loop shares a mailbox with.
fn pull(peer: PeerSpec, cursor: Int) -> Result(#(List(Whisper), Int), String) {
  let url = peer.url <> "/t/*?since=" <> int.to_string(cursor)
  use req <- result.try(
    request.to(url) |> result.replace_error("bad peer url: " <> url),
  )
  let req = request.set_header(req, "authorization", "Bearer " <> peer.token)
  use resp <- result.try(case rescue(fn() { httpc.send(req) }) {
    Ok(sent) ->
      sent
      |> result.map_error(fn(e) { poller.describe_error(e) <> " for " <> url })
    Error(crash) -> Error("transport error " <> crash <> " for " <> url)
  })
  use #(whispers, next_since, _more) <- result.try(case resp.status {
    200 ->
      wire.parse_since_response(resp.body)
      |> result.map_error(fn(reason) { reason <> " from " <> url })
    status -> Error("status " <> int.to_string(status) <> " from " <> url)
  })
  Ok(#(whispers, next_since))
}
