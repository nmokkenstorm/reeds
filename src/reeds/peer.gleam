import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
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
/// pull loop actor.
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

/// Supervised child spec: a crashed pull loop restarts clean and resumes
/// from whatever cursor was last persisted.
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

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Tick = msg
  let peer = state.peer
  let cursor =
    process.call(state.hub, waiting: 5000, sending: hub.GetPeerCursor(
      peer.name,
      _,
    ))
  let down_streak = case pull(peer, cursor) {
    Error(reason) -> {
      io.println("reeds: peer " <> peer.name <> " pull failed: " <> reason)
      record_poll(state, [health.Unreachable("pull", reason)])
    }
    Ok(#(whispers, next_cursor)) -> {
      ingest(state, whispers)
      process.send(state.hub, hub.PutPeerCursor(peer.name, next_cursor))
      record_poll(state, [health.Reached("pull")])
    }
  }
  process.send_after(
    state.self,
    health.backoff(peer.interval_ms, down_streak, peer.backoff_cap_ms),
    Tick,
  )
  actor.continue(state)
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
