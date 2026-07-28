import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import reeds/hub

/// A Source polls some upstream, diffs against its persisted state, and
/// returns whispers to publish. Implementations own the diffing; the runner
/// owns scheduling and state persistence.
pub type Source {
  Source(
    name: String,
    interval_ms: Int,
    poll: fn(Option(String)) -> #(Option(String), List(Draft)),
  )
}

pub type Draft {
  Draft(topic: String, kind: String, body: String)
}

pub opaque type Msg {
  Tick
}

type State {
  State(source: Source, hub: Subject(hub.Msg), self: Subject(Msg))
}

pub fn start(
  source: Source,
  hub: Subject(hub.Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Tick)
    State(source:, hub:, self:)
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
  let source = state.source
  let previous =
    process.call(state.hub, waiting: 5000, sending: hub.GetSourceState(
      source.name,
      _,
    ))
  let #(next, drafts) = source.poll(previous)
  list.each(drafts, fn(draft) {
    process.call(state.hub, waiting: 5000, sending: hub.Publish(
      draft.topic,
      source.name,
      draft.kind,
      draft.body,
      _,
    ))
    |> result.map_error(fn(error) {
      io.println(
        "reeds: source " <> source.name <> " publish failed: " <> error,
      )
    })
  })
  case next {
    Some(next_state) ->
      process.send(state.hub, hub.PutSourceState(source.name, next_state))
    option.None -> Nil
  }
  process.send_after(state.self, source.interval_ms, Tick)
  actor.continue(state)
}
