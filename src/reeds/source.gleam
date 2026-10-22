import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import reeds/health
import reeds/hub
import reeds/hub_call
import reeds/logs

/// A Source polls some upstream, diffs against its persisted state, and
/// returns whispers to publish. Implementations own the diffing; the runner
/// owns scheduling, state persistence, and backoff.
pub type Source {
  Source(
    name: String,
    interval_ms: Int,
    backoff_cap_ms: Int,
    poll: fn(Option(String)) -> Poll,
  )
}

/// The result of one tick: the next diff baseline, the whispers to publish,
/// and whether each polled collection was reachable. Reachability is a
/// separate channel from the drafts on purpose: when failure is just another
/// draft, the runner cannot tell a working poll from a broken one, so it
/// cannot back off and the hub cannot report health.
pub type Poll {
  Poll(
    baseline: Option(String),
    drafts: List(Draft),
    feeds: List(health.FeedOutcome),
  )
}

pub type Draft {
  Draft(topic: String, kind: String, body: String, idem: Option(String))
}

pub opaque type Msg {
  Tick
}

type State {
  State(
    source: Source,
    hub: Subject(hub.Msg),
    self: Subject(Msg),
    timeout_ms: Int,
  )
}

/// Supervised child spec: a crashed source restarts clean and reloads its
/// diff baseline from the hub on the first tick.
pub fn supervised(
  source: Source,
  hub: Subject(hub.Msg),
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(source, hub) })
}

pub fn start(
  source: Source,
  hub: Subject(hub.Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  start_within(source, hub, hub_call.default_timeout_ms)
}

pub fn start_within(
  source: Source,
  hub: Subject(hub.Msg),
  timeout_ms: Int,
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Tick)
    State(source:, hub:, self:, timeout_ms:)
    |> actor.initialised
    |> actor.selecting(process.new_selector() |> process.select(self))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

/// A hub that misses its deadline costs this tick, never the actor: with the
/// baseline unknown the poll is skipped (polling blind would republish
/// everything), and the next tick retries on the plain interval.
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Tick = msg
  let source = state.source
  let delay = case
    hub_call.call(
      state.hub,
      state.timeout_ms,
      "GetSourceState",
      hub.GetSourceState(source.name, _),
    )
  {
    Error(failure) -> {
      log_miss(source, failure)
      source.interval_ms
    }
    Ok(previous) -> poll_and_publish(state, previous)
  }
  process.send_after(state.self, delay, Tick)
  actor.continue(state)
}

fn poll_and_publish(state: State, previous: Option(String)) -> Int {
  let source = state.source
  let poll = source.poll(previous)
  let published =
    list.fold_until(poll.drafts, True, fn(all_ok, draft) {
      let outcome =
        hub_call.call(state.hub, state.timeout_ms, "Publish", hub.Publish(
          draft.topic,
          source.name,
          draft.kind,
          draft.body,
          draft.idem,
          _,
        ))
      case outcome {
        Error(failure) -> {
          log_miss(source, failure)
          list.Stop(False)
        }
        Ok(Error(error)) -> {
          logs.warning(
            "reeds: source " <> source.name <> " publish failed: " <> error,
          )
          list.Continue(False)
        }
        Ok(Ok(_)) -> list.Continue(all_ok)
      }
    })
  // A failed publish keeps the old baseline, so the drafts are rebuilt and
  // retried next poll instead of being lost forever.
  case poll.baseline, published {
    Some(next_state), True ->
      process.send(state.hub, hub.PutSourceState(source.name, next_state))
    _, _ -> Nil
  }
  // The hub answers with the all-feeds-failing streak, so backoff policy
  // stays here with the rest of the scheduling.
  let down_streak =
    hub_call.call(state.hub, state.timeout_ms, "RecordPoll", hub.RecordPoll(
      source.name,
      poll.feeds,
      _,
    ))
    |> result.map_error(log_miss(source, _))
    |> result.unwrap(0)
  health.backoff(source.interval_ms, down_streak, source.backoff_cap_ms)
}

fn log_miss(source: Source, failure: hub_call.Failure) -> Nil {
  logs.warning(
    "reeds: source " <> source.name <> ": " <> hub_call.describe(failure),
  )
}
