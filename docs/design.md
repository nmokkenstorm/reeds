# Design notes

- All writes and subscription attach go through one hub actor, so SSE replay
  and live delivery cannot interleave: streams are gapless and ordered.
- SQLite runs STRICT tables with a `json_valid` check; malformed whispers are
  rejected at the door, not discovered during decode.
- Source state (the diff baseline) persists in the same database, so a daemon
  restart does not refire old events.
- Health is written and its transition whisper emitted in the same hub message,
  so the two cannot disagree about when a source broke. Backoff lives in the
  source runner, with the rest of the scheduling.

Everything runs under one OTP supervision tree (one-for-one): the hub is a
named process, so a crashed hub restarts without invalidating the subject
that sources and the HTTP layer hold, and a crashed source restarts clean
and reloads its diff baseline on the next tick. One caveat: a hub restart
drops the in-memory subscriber list, so SSE clients see silence until they
reconnect; `since`-cursor pulls are unaffected. launchd remains the backstop
for whole-VM death.
