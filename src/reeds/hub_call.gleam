import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/result
import reeds/clock
import reeds/hub

pub const default_timeout_ms = 5000

const slow_ms = 500

const helper_grace_ms = 1000

pub type Failure {
  TimedOut(kind: String, waited_ms: Int)
}

@external(erlang, "reeds_mailbox_ffi", "len")
fn mailbox_len(pid: Pid) -> Result(Int, Nil)

/// A hub call that reports a missed deadline as a value instead of crashing
/// the caller. `kind` names the message in the log: a call over `slow_ms`
/// and a timeout both leave a line with the hub's mailbox length, which is
/// the evidence a stall needs. The hub is asked from a short-lived helper
/// that owns the reply subject, so a reply arriving after the deadline goes
/// to a dead process and never reaches the caller's mailbox, where an actor
/// would log the whole payload as an unexpected message.
pub fn call(
  hub: Subject(hub.Msg),
  waiting timeout_ms: Int,
  kind kind: String,
  sending make: fn(Subject(reply)) -> hub.Msg,
) -> Result(reply, Failure) {
  let result = process.new_subject()
  let started = clock.now_ms()
  let helper =
    process.spawn_unlinked(fn() {
      let reply = process.new_subject()
      process.send(hub, make(reply))
      process.send(result, process.receive(reply, timeout_ms))
    })
  let monitor = process.monitor(helper)
  let selector =
    process.new_selector()
    |> process.select(result)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
  let outcome =
    process.selector_receive(selector, timeout_ms + helper_grace_ms)
    |> result.unwrap(Error(Nil))
  process.kill(helper)
  process.demonitor_process(monitor)
  settle(helper, result)
  let elapsed = clock.now_ms() - started
  case outcome {
    Ok(value) -> {
      case elapsed >= slow_ms {
        True -> log("slow hub call " <> kind, elapsed, hub)
        False -> Nil
      }
      Ok(value)
    }
    Error(Nil) -> {
      log("hub call " <> kind <> " timed out", elapsed, hub)
      Error(TimedOut(kind:, waited_ms: timeout_ms))
    }
  }
}

/// Once the helper is confirmed dead nothing more can be sent from it, so
/// draining the result subject afterwards leaves no `Result` behind. A fresh
/// monitor on an already dead pid fires at once.
fn settle(helper: Pid, result: Subject(Result(reply, Nil))) -> Nil {
  let down = process.monitor(helper)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(_down) { Nil })
    |> process.selector_receive(1000)
  process.demonitor_process(down)
  let _ = process.receive(result, 0)
  Nil
}

pub fn describe(failure: Failure) -> String {
  let TimedOut(kind:, waited_ms:) = failure
  "hub did not answer "
  <> kind
  <> " within "
  <> int.to_string(waited_ms)
  <> "ms"
}

fn log(what: String, elapsed: Int, hub: Subject(hub.Msg)) -> Nil {
  let mailbox =
    process.subject_owner(hub)
    |> result.try(mailbox_len)
    |> result.map(int.to_string)
    |> result.unwrap("unknown")
  io.println(
    "reeds: "
    <> what
    <> " after "
    <> int.to_string(elapsed)
    <> "ms (hub mailbox: "
    <> mailbox
    <> ")",
  )
}
