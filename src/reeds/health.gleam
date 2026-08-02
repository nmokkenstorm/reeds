import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// How many times a backoff may double before the cap does the work. Purely
/// a guard: without it a source down for a week builds a thousand-bit int
/// only to throw it away against the cap.
const max_doublings = 32

/// Reachability of one polled collection, keyed by the poller's own state-key
/// namespace (`<ns>:<repo>`, e.g. `pr:web`) so health and diff state
/// share a vocabulary. Per-feed rather than per-repo because a repo with
/// Actions switched off 404s its runs feed forever while its PRs feed is
/// fine, and that difference is the whole diagnosis.
pub type FeedHealth {
  FeedHealth(
    feed: String,
    last_ok_ts: Option(Int),
    consecutive_failures: Int,
    last_error: Option(String),
    last_error_ts: Option(Int),
  )
}

/// What one poll learned about one feed. Lives here rather than in `source`
/// so the hub can name it in a message without importing the module that
/// imports the hub.
pub type FeedOutcome {
  Reached(feed: String)
  Unreachable(feed: String, reason: String)
}

pub type Failure {
  Failure(feed: String, reason: String)
}

/// A configured source, whether or not it has ever polled. `/health` reports
/// the roster rather than whatever rows happen to exist, so a source cannot
/// go missing from the report the way it cannot go missing at boot.
pub type Registration {
  Registration(name: String, kind: String, enabled: Bool)
}

pub type State {
  /// Every feed reached upstream on the last poll.
  Healthy
  /// Some feeds are failing, but not all: no backoff, one flaky feed must
  /// not slow down the healthy ones.
  Degraded
  /// Every feed failed the last poll. The only state that backs off.
  Down
  /// Configured with `enabled = false`; parked, not broken.
  Disabled
  /// Configured and enabled, but has not completed a poll yet.
  Unknown
}

/// Always derived from feed rows, never stored. A stored source-level row is
/// a denormalised copy that can drift out of sync with the feeds it claims
/// to summarise.
pub type SourceHealth {
  SourceHealth(
    name: String,
    kind: String,
    state: State,
    feeds_ok: Int,
    feeds_total: Int,
    down_streak: Int,
    last_success_ts: Option(Int),
    last_failure: Option(Failure),
  )
}

pub fn state_name(state: State) -> String {
  case state {
    Healthy -> "healthy"
    Degraded -> "degraded"
    Down -> "down"
    Disabled -> "disabled"
    Unknown -> "unknown"
  }
}

/// `down_streak` is the minimum failure streak across feeds: every feed is
/// attempted on every poll, so if all of them are at N or more, the last N
/// polls each had every feed failing.
pub fn summarise(
  name: String,
  kind: String,
  enabled: Bool,
  feeds: List(FeedHealth),
) -> SourceHealth {
  let empty =
    SourceHealth(
      name:,
      kind:,
      state: Unknown,
      feeds_ok: 0,
      feeds_total: 0,
      down_streak: 0,
      last_success_ts: None,
      last_failure: None,
    )
  case enabled, feeds {
    False, _ -> SourceHealth(..empty, state: Disabled)
    True, [] -> empty
    True, _ -> {
      let streaks = list.map(feeds, fn(feed) { feed.consecutive_failures })
      let down_streak = list.reduce(streaks, int.min) |> option.from_result
      let down_streak = option.unwrap(down_streak, 0)
      let feeds_ok = list.count(streaks, fn(streak) { streak == 0 })
      let feeds_total = list.length(feeds)
      SourceHealth(
        ..empty,
        state: case down_streak > 0, feeds_ok < feeds_total {
          True, _ -> Down
          False, True -> Degraded
          False, False -> Healthy
        },
        feeds_ok:,
        feeds_total:,
        down_streak:,
        last_success_ts: latest(feeds, fn(feed) { feed.last_ok_ts }),
        last_failure: latest_failure(feeds),
      )
    }
  }
}

fn latest(
  feeds: List(FeedHealth),
  pick: fn(FeedHealth) -> Option(Int),
) -> Option(Int) {
  list.fold(feeds, None, fn(best, feed) {
    case pick(feed), best {
      Some(ts), Some(seen) -> Some(int.max(ts, seen))
      Some(ts), None -> Some(ts)
      None, seen -> seen
    }
  })
}

/// The most recently recorded failure across feeds, so a down source reports
/// the reason a human needs rather than an arbitrary one.
fn latest_failure(feeds: List(FeedHealth)) -> Option(Failure) {
  feeds
  |> list.fold(#(None, None), fn(best, feed) {
    let #(best_ts, _) = best
    case feed.last_error, feed.last_error_ts, best_ts {
      Some(_), Some(ts), Some(seen) if ts <= seen -> best
      Some(reason), Some(ts), _ -> #(
        Some(ts),
        Some(Failure(feed: feed.feed, reason:)),
      )
      _, _, _ -> best
    }
  })
  |> pair_second
}

fn pair_second(pair: #(Option(Int), Option(Failure))) -> Option(Failure) {
  pair.1
}

/// Exponential backoff, applied only to a fully-down source. A `Degraded`
/// source keeps its base interval on purpose.
pub fn backoff(base_ms: Int, down_streak: Int, cap_ms: Int) -> Int {
  case down_streak <= 0 {
    True -> base_ms
    False ->
      int.min(base_ms * double(int.min(down_streak - 1, max_doublings)), cap_ms)
  }
}

fn double(times: Int) -> Int {
  case times <= 0 {
    True -> 1
    False -> 2 * double(times - 1)
  }
}

pub type Announcement {
  Announcement(kind: String, body: String)
}

/// Whisper on a change of state or of reason, and on nothing else: 401 to 403
/// is new information, the same 401 for the 2941st time is not.
pub fn announce(
  before: Option(SourceHealth),
  after: SourceHealth,
  now_ms: Int,
) -> Option(Announcement) {
  case signature(before) == signature(Some(after)) {
    True -> None
    False ->
      case after.state {
        Down -> Some(Announcement(kind: "source.down", body: failing(after)))
        Degraded ->
          Some(Announcement(kind: "source.degraded", body: failing(after)))
        // Only announce recovery from something that was announced as
        // broken; a source polling cleanly for the first time is not news.
        Healthy ->
          case before {
            Some(previous) ->
              case previous.state {
                Down | Degraded ->
                  Some(Announcement(
                    kind: "source.recovered",
                    body: recovered(after, previous, now_ms),
                  ))
                _ -> None
              }
            None -> None
          }
        Disabled | Unknown -> None
      }
  }
}

fn signature(health: Option(SourceHealth)) -> Option(#(String, String)) {
  case health {
    None -> None
    Some(health) ->
      Some(
        #(state_name(health.state), case health.last_failure {
          Some(failure) -> failure.feed <> " " <> failure.reason
          None -> ""
        }),
      )
  }
}

fn failing(health: SourceHealth) -> String {
  let base = [
    #("state", json.string(state_name(health.state))),
    #("feeds_ok", json.int(health.feeds_ok)),
    #("feeds_total", json.int(health.feeds_total)),
    #("consecutive_failures", json.int(health.down_streak)),
    #("last_success_ts", json.nullable(health.last_success_ts, json.int)),
  ]
  json.object(case health.last_failure {
    Some(failure) ->
      list.append(base, [
        #("feed", json.string(failure.feed)),
        #("reason", json.string(failure.reason)),
      ])
    None -> base
  })
  |> json.to_string
}

fn recovered(
  health: SourceHealth,
  previous: SourceHealth,
  now_ms: Int,
) -> String {
  json.object([
    #("state", json.string(state_name(health.state))),
    #("feeds_ok", json.int(health.feeds_ok)),
    #("feeds_total", json.int(health.feeds_total)),
    #("was", json.string(state_name(previous.state))),
    #(
      "down_for_ms",
      json.nullable(
        option.map(previous.last_success_ts, fn(ts) { now_ms - ts }),
        json.int,
      ),
    ),
  ])
  |> json.to_string
}

/// `ok` is false when any source is fully down. A degraded source is a
/// warning, not a failure: the network is still delivering.
pub fn all_ok(sources: List(SourceHealth)) -> Bool {
  !list.any(sources, fn(source) { source.state == Down })
}

pub fn to_json(sources: List(SourceHealth)) -> String {
  json.object([
    #("ok", json.bool(all_ok(sources))),
    #("sources", json.array(sources, source_json)),
  ])
  |> json.to_string
}

fn source_json(health: SourceHealth) -> json.Json {
  let base = [
    #("name", json.string(health.name)),
    #("kind", json.string(health.kind)),
    #("state", json.string(state_name(health.state))),
    #("feeds_ok", json.int(health.feeds_ok)),
    #("feeds_total", json.int(health.feeds_total)),
    #("consecutive_failures", json.int(health.down_streak)),
    #("last_success_ts", json.nullable(health.last_success_ts, json.int)),
  ]
  json.object(case health.last_failure {
    Some(failure) ->
      list.append(base, [
        #(
          "last_error",
          json.object([
            #("feed", json.string(failure.feed)),
            #("reason", json.string(failure.reason)),
          ]),
        ),
      ])
    None -> base
  })
}
