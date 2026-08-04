import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import reeds/clock
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

/// Per-direction backoff bookkeeping, in actor memory: a supervisor restart
/// resets it, which merely retries sooner. `last` is re-reported while the
/// direction cools down so the shared health source keeps both feed rows
/// alive (an omitted feed would be pruned).
type Direction {
  Direction(streak: Int, due_at_ms: Int, last: Option(health.FeedOutcome))
}

fn fresh() -> Direction {
  Direction(streak: 0, due_at_ms: 0, last: None)
}

type State {
  State(
    peer: PeerSpec,
    hub: Subject(hub.Msg),
    self: Subject(Msg),
    pull: Direction,
    push: Direction,
  )
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
    State(peer:, hub:, self:, pull: fresh(), push: fresh())
    |> actor.initialised
    |> actor.selecting(process.new_selector() |> process.select(self))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

/// One tick runs every direction the mode asks for and reports them as
/// feeds of one health source in one `RecordPoll`: recording per direction
/// would prune the other direction's row, and one shared source is what
/// makes `degraded` mean "one direction failing", which is the diagnosis.
/// Ticks stay on the base interval; each direction backs off on its own
/// streak, since the min-streak rule sources use would never slow a wedged
/// push while pull stays healthy.
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Tick = msg
  let peer = state.peer
  let now = clock.now_ms()
  let pull_dir = case peer.mode {
    config.Push -> state.pull
    _ -> attempt(state.pull, now, peer, fn() { run_pull(state) })
  }
  let push_dir = case peer.mode {
    config.Pull -> state.push
    _ -> attempt(state.push, now, peer, fn() { run_push(state) })
  }
  let outcomes =
    list.append(option.values([pull_dir.last]), option.values([push_dir.last]))
  let _ = record_poll(state, outcomes)
  process.send_after(state.self, peer.interval_ms, Tick)
  actor.continue(State(..state, pull: pull_dir, push: push_dir))
}

fn attempt(
  dir: Direction,
  now: Int,
  peer: PeerSpec,
  run: fn() -> health.FeedOutcome,
) -> Direction {
  case now < dir.due_at_ms {
    True -> dir
    False ->
      case run() {
        health.Reached(_) as outcome ->
          Direction(streak: 0, due_at_ms: 0, last: Some(outcome))
        outcome -> {
          let streak = dir.streak + 1
          Direction(
            streak:,
            due_at_ms: now
              + health.backoff(peer.interval_ms, streak, peer.backoff_cap_ms),
            last: Some(outcome),
          )
        }
      }
  }
}

/// The cursor only advances once the page is ingested: advancing past
/// whispers the store refused (disk full mid-page) would lose them
/// permanently, since nothing ever asks for that range again. Reasons are
/// prefixed `local` when this bridge, not the peer, is what failed.
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
    Ok(#(whispers, next_cursor)) ->
      case ingest(state, whispers) {
        Error(reason) -> {
          io.println("reeds: peer " <> peer.name <> " ingest failed: " <> reason)
          health.Unreachable("pull", "local ingest failed: " <> reason)
        }
        Ok(_) -> {
          process.send(state.hub, hub.PutPeerCursor(peer.name, next_cursor))
          health.Reached("pull")
        }
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
  case
    process.call(state.hub, waiting: 5000, sending: hub.ReadSince(
      "*",
      cursor,
      push_batch,
      _,
    ))
  {
    Error(reason) ->
      health.Unreachable("push", "local read failed: " <> reason)
    Ok(whispers) -> {
      let batch = chunk(whispers, push_body_budget)
      let more =
        list.length(whispers) == push_batch
        || list.length(batch) < list.length(whispers)
      case push(peer, batch, cursor, more) {
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
  }
}

/// The longest prefix whose serialized whispers fit the byte budget, but
/// never fewer than one: `/ingest` accepts double the publish limit, so
/// even a maximum-size lone whisper fits and no whisper can wedge the loop.
pub fn chunk(whispers: List(Whisper), budget: Int) -> List(Whisper) {
  case whispers {
    [] -> []
    [first, ..rest] -> {
      let first_size = string.byte_size(whisper.to_json_string(first))
      let #(_, taken) =
        list.fold_until(rest, #(first_size, [first]), fn(acc, w) {
          let #(size, taken) = acc
          let next = size + 1 + string.byte_size(whisper.to_json_string(w))
          case next > budget {
            True -> list.Stop(acc)
            False -> list.Continue(#(next, [w, ..taken]))
          }
        })
      list.reverse(taken)
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
fn ingest(state: State, whispers: List(Whisper)) -> Result(Int, String) {
  case whispers {
    [] -> Ok(0)
    _ ->
      process.call(state.hub, waiting: 5000, sending: hub.IngestForeign(
        whispers,
        _,
      ))
  }
}

fn record_poll(state: State, outcomes: List(health.FeedOutcome)) -> Int {
  process.call(state.hub, waiting: 5000, sending: hub.RecordPoll(
    health_name(state.peer),
    outcomes,
    _,
  ))
}

/// One read page per tick; `push_body_budget` below is the real bound on
/// what each POST carries, the count only caps the hub read.
const push_batch = 500

/// One publish-limit body still fits `/ingest`'s doubled limit even alone
/// in its envelope; a whole batch capped here stays comfortably inside it.
const push_body_budget = 1_048_576

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
  more: Bool,
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
      more:,
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
