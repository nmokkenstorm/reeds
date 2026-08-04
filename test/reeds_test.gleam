import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import mist
import reeds/api
import reeds/config
import reeds/health
import reeds/host
import reeds/hub
import reeds/peer
import reeds/sources/bitbucket
import reeds/sources/github
import reeds/sources/gitlab
import reeds/sources/poller
import reeds/store
import reeds/whisper.{type Whisper, Whisper}
import reeds/wire
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn matches_test() {
  [
    #("bb.pr.api.12", "bb.pr", True),
    #("bb.pr", "bb.pr", True),
    #("bb.private", "bb.pr", False),
    #("bb.pr.x", "bb", True),
    #("other", "bb", False),
    #("anything.at.all", "*", True),
    #("bb", "bb.pr", False),
  ]
  |> list.each(fn(case_) {
    let #(topic, prefix, expected) = case_
    assert whisper.matches(topic:, prefix:) == expected
  })
}

pub fn valid_topic_test() {
  [
    #("bb.pr.api.12", True),
    #("agents.turtle", True),
    #("snake_case.ok-too", True),
    #("", False),
    #("bb..pr", False),
    #(".leading", False),
    #("trailing.", False),
    #("Uppercase.no", False),
    #("spa ce.no", False),
    #("per%cent.no", False),
  ]
  |> list.each(fn(case_) {
    let #(topic, expected) = case_
    assert whisper.valid_topic(topic) == expected
  })
}

pub fn envelope_test() {
  let w =
    Whisper(
      seq: 7,
      topic: "a.b",
      ts: 123,
      sender: "turtle",
      kind: "note",
      body: "{\"msg\":\"carry on\"}",
      origin: "hub1",
      origin_seq: 7,
      idem: None,
    )
  assert whisper.to_json_string(w)
    == "{\"seq\":7,\"topic\":\"a.b\",\"ts\":123,\"sender\":\"turtle\",\"kind\":\"note\",\"origin\":\"hub1\",\"origin_seq\":7,\"idem\":null,\"body\":{\"msg\":\"carry on\"}}"
}

pub fn envelope_with_idem_test() {
  let w =
    Whisper(
      seq: 1,
      topic: "gh.pr.tools.7",
      ts: 1,
      sender: "gh",
      kind: "pr.seen",
      body: "{}",
      origin: "hub1",
      origin_seq: 1,
      idem: Some("7:2026-07-28T09:00:00Z"),
    )
  assert whisper.to_json_string(w)
    == "{\"seq\":1,\"topic\":\"gh.pr.tools.7\",\"ts\":1,\"sender\":\"gh\",\"kind\":\"pr.seen\",\"origin\":\"hub1\",\"origin_seq\":1,\"idem\":\"7:2026-07-28T09:00:00Z\",\"body\":{}}"
}

fn since_envelope(
  whispers: List(Whisper),
  next_since: Int,
  more: Bool,
) -> String {
  let more_text = case more {
    True -> "true"
    False -> "false"
  }
  "{\"whispers\":"
  <> whisper.list_to_json_string(whispers)
  <> ",\"next_since\":"
  <> int.to_string(next_since)
  <> ",\"more\":"
  <> more_text
  <> "}"
}

/// The pull loop must recover a whisper byte-for-byte, including a body
/// whose own nested content could be mistaken for structure at the wrong
/// scan level: braces, brackets, a comma, and an escaped quote.
pub fn wire_parse_since_response_test() {
  let tricky_body =
    "{\"nested\":{\"list\":[1,2,{\"a\":\"b,c\"}]},\"quote\":\"she said \\\"hi\\\"\"}"
  let whispers = [
    Whisper(
      seq: 1,
      topic: "gh.pr.tools.7",
      ts: 100,
      sender: "gh",
      kind: "pr.seen",
      body: tricky_body,
      origin: "hub2",
      origin_seq: 1,
      idem: Some("7:2026-07-28T09:00:00Z"),
    ),
    Whisper(
      seq: 2,
      topic: "agents.turtle",
      ts: 200,
      sender: "turtle",
      kind: "note",
      body: "{\"msg\":\"carry on\"}",
      origin: "hub2",
      origin_seq: 2,
      idem: None,
    ),
  ]
  let text = since_envelope(whispers, 2, False)
  let assert Ok(#(parsed, next_since, more)) = wire.parse_since_response(text)
  assert parsed == whispers
  assert next_since == 2
  assert more == False
}

pub fn wire_parse_since_response_empty_test() {
  let text = since_envelope([], 0, False)
  let assert Ok(#([], 0, False)) = wire.parse_since_response(text)
}

pub fn wire_parse_since_response_more_true_test() {
  let text = since_envelope([], 5, True)
  let assert Ok(#([], 5, True)) = wire.parse_since_response(text)
}

pub fn wire_parse_since_response_rejects_garbage_test() {
  let assert Error(_) = wire.parse_since_response("not json at all")
  let assert Error(_) = wire.parse_since_response("{\"next_since\":1}")
}

pub fn store_roundtrip_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(store.Inserted(seq: 1, origin_seq: 1)) =
    store.append(
      conn,
      topic: "a.b",
      ts: 1,
      sender: "t",
      kind: "note",
      body: "{}",
      origin: "hub1",
      idem: None,
    )
  let assert Ok(store.Inserted(seq: 2, origin_seq: 2)) =
    store.append(
      conn,
      topic: "a.c",
      ts: 2,
      sender: "t",
      kind: "note",
      body: "{}",
      origin: "hub1",
      idem: None,
    )
  let assert Ok(store.Inserted(seq: 3, origin_seq: 3)) =
    store.append(
      conn,
      topic: "ax",
      ts: 3,
      sender: "t",
      kind: "note",
      body: "{}",
      origin: "hub1",
      idem: None,
    )

  let assert Ok([one, two]) =
    store.read_since(conn, prefix: "a", since: 0, limit: 10)
  assert one.topic == "a.b"
  assert one.origin == "hub1"
  assert one.origin_seq == 1
  assert one.idem == None
  assert two.topic == "a.c"

  let assert Ok([only]) =
    store.read_since(conn, prefix: "*", since: 2, limit: 10)
  assert only.topic == "ax"

  let assert Ok([]) =
    store.read_since(conn, prefix: "nope", since: 0, limit: 10)
}

/// Re-publishing a source fact with the same `(topic, idem)` no-ops rather
/// than erroring or inserting a second row, and reports the existing seq.
pub fn store_idem_dedup_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(store.Inserted(seq: 1, origin_seq: 1)) =
    store.append(
      conn,
      topic: "gh.pr.tools.7",
      ts: 1,
      sender: "gh",
      kind: "pr.seen",
      body: "{}",
      origin: "hub1",
      idem: Some("7:2026-07-28T09:00:00Z"),
    )
  let assert Ok(store.Deduped(seq: 1)) =
    store.append(
      conn,
      topic: "gh.pr.tools.7",
      ts: 2,
      sender: "gh",
      kind: "pr.updated",
      body: "{\"different\":true}",
      origin: "hub1",
      idem: Some("7:2026-07-28T09:00:00Z"),
    )
  let assert Ok([only]) =
    store.read_since(conn, prefix: "*", since: 0, limit: 10)
  assert only.kind == "pr.seen"

  // A different topic with the same idem string is not the same fact. `seq`
  // may skip a value here: SQLite's AUTOINCREMENT burns a rowid even for an
  // insert that a later UNIQUE conflict causes it to ignore.
  let assert Ok(store.Inserted(origin_seq: 2, ..)) =
    store.append(
      conn,
      topic: "gh.pr.tools.8",
      ts: 3,
      sender: "gh",
      kind: "pr.seen",
      body: "{}",
      origin: "hub1",
      idem: Some("7:2026-07-28T09:00:00Z"),
    )
}

/// `origin_seq` is a per-origin counter computed alongside `seq`, so two
/// origins interleaving in one log each count from their own one.
pub fn store_origin_seq_per_origin_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(store.Inserted(seq: 1, origin_seq: 1)) =
    store.append(
      conn,
      topic: "a",
      ts: 1,
      sender: "t",
      kind: "note",
      body: "{}",
      origin: "hub1",
      idem: None,
    )
  let assert Ok(Some(2)) =
    store.append_foreign(
      conn,
      Whisper(
        seq: 0,
        topic: "b",
        ts: 2,
        sender: "t",
        kind: "note",
        body: "{}",
        origin: "hub2",
        origin_seq: 41,
        idem: None,
      ),
    )
  let assert Ok(store.Inserted(seq: 3, origin_seq: 2)) =
    store.append(
      conn,
      topic: "a",
      ts: 3,
      sender: "t",
      kind: "note",
      body: "{}",
      origin: "hub1",
      idem: None,
    )
}

/// Foreign ingest preserves origin/origin_seq/idem verbatim; a duplicate
/// `(origin, origin_seq)` no-ops instead of erroring, which is what makes a
/// resumed pull safe to replay.
pub fn store_append_foreign_dedup_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let w =
    Whisper(
      seq: 0,
      topic: "gl.mr.app.14",
      ts: 5,
      sender: "gl",
      kind: "mr.seen",
      body: "{}",
      origin: "hub2",
      origin_seq: 9,
      idem: Some("14:2026-07-28T11:00:00Z"),
    )
  let assert Ok(Some(seq)) = store.append_foreign(conn, w)
  let assert Ok(None) = store.append_foreign(conn, w)
  let assert Ok([only]) =
    store.read_since(conn, prefix: "*", since: 0, limit: 10)
  assert only.seq == seq
  assert only.origin == "hub2"
  assert only.origin_seq == 9
}

pub fn store_rejects_invalid_json_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Error(_) =
    store.append(
      conn,
      topic: "a",
      ts: 1,
      sender: "t",
      kind: "note",
      body: "not json",
      origin: "hub1",
      idem: None,
    )
}

/// A database created before origin tagging existed gets its rows
/// backfilled (`origin = <bridge.name>`, `origin_seq = seq`) rather than
/// refusing to open, and the mesh columns work from then on.
pub fn store_migrates_legacy_schema_test() {
  let path = "/tmp/reeds_test_legacy_schema.db"
  let _ = simplifile.delete(path)
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(Nil) =
    sqlight.exec(
      "create table messages(
         seq    integer primary key autoincrement,
         topic  text not null,
         ts     integer not null,
         sender text not null,
         kind   text not null,
         body   text not null check (json_valid(body))
       ) strict;",
      conn,
    )
  let assert Ok(Nil) =
    sqlight.exec(
      "insert into messages(topic, ts, sender, kind, body)
       values ('legacy.a', 1, 't', 'note', '{}');",
      conn,
    )
  let assert Ok(Nil) = sqlight.close(conn)

  let assert Ok(migrated) = store.open(path, origin: "hub1")
  let assert Ok([row]) =
    store.read_since(migrated, prefix: "*", since: 0, limit: 10)
  assert row.topic == "legacy.a"
  assert row.origin == "hub1"
  assert row.origin_seq == row.seq
  assert row.idem == None

  let assert Ok(store.Inserted(seq: _, origin_seq: next_origin_seq)) =
    store.append(
      migrated,
      topic: "legacy.b",
      ts: 2,
      sender: "t",
      kind: "note",
      body: "{}",
      origin: "hub1",
      idem: None,
    )
  assert next_origin_seq == row.origin_seq + 1
  let assert Ok(Nil) = sqlight.close(migrated)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn source_state_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(None) = store.get_source_state(conn, "bitbucket")
  let assert Ok(Nil) =
    store.put_source_state(conn, "bitbucket", "{\"a\":\"1\"}")
  let assert Ok(Nil) =
    store.put_source_state(conn, "bitbucket", "{\"a\":\"2\"}")
  let assert Ok(Some("{\"a\":\"2\"}")) =
    store.get_source_state(conn, "bitbucket")
}

/// An unpolled peer starts at cursor 0, same as `since=0` on the read API.
pub fn peer_cursor_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(0) = store.get_peer_cursor(conn, "hub2")
  let assert Ok(Nil) = store.put_peer_cursor(conn, "hub2", 12)
  let assert Ok(12) = store.get_peer_cursor(conn, "hub2")
  let assert Ok(Nil) = store.put_peer_cursor(conn, "hub2", 40)
  let assert Ok(40) = store.get_peer_cursor(conn, "hub2")
}

pub fn config_parse_test() {
  let raw =
    "port = 7444\ndb = \"/tmp/x.db\"\n\n[sources.work]\nkind = \"bitbucket\"\nworkspace = \"w\"\nrepos = [\"r\"]\ntoken = \"t\"\n"
  let assert Ok(parsed) = config.parse(raw)
  assert parsed.port == 7444
  assert parsed.db == "/tmp/x.db"
  let assert [
    config.SourceSpec(name: "work", kind: "bitbucket", enabled: True, table: _),
  ] = parsed.sources
}

pub fn config_source_enabled_test() {
  let cases = [#("enabled = false\n", False), #("enabled = true\n", True)]
  list.each(cases, fn(item) {
    let #(line, expected) = item
    let raw = "[sources.work]\nkind = \"bitbucket\"\n" <> line
    let assert Ok(parsed) = config.parse(raw)
    let assert [spec] = parsed.sources
    assert spec.enabled == expected
  })
}

pub fn config_rejects_wrong_typed_enabled_test() {
  let assert Error(_) =
    config.parse("[sources.work]\nkind = \"bitbucket\"\nenabled = \"no\"\n")
}

pub fn config_defaults_test() {
  let assert Ok(parsed) = config.parse("")
  assert parsed
    == config.Config(
      port: 7333,
      bind: "localhost",
      db: "reeds.db",
      bridge_name: host.hostname(),
      sources: [],
      peers: [],
    )
}

pub fn config_peers_test() {
  let raw =
    "[peers.rendezvous]\nurl = \"http://hub2:7333\"\ntoken = \"t\"\nmode = \"push\"\ninterval_seconds = 60\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [peer] = parsed.peers
  assert peer.name == "rendezvous"
  assert peer.url == "http://hub2:7333"
  assert peer.token == "t"
  assert peer.mode == config.Push
  assert peer.interval_ms == 60_000
}

pub fn config_peer_mode_default_is_pull_test() {
  let raw = "[peers.hub2]\nurl = \"http://hub2:7333\"\ntoken = \"t\"\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [peer] = parsed.peers
  assert peer.mode == config.Pull
}

pub fn config_peer_rejects_bad_mode_test() {
  let raw =
    "[peers.hub2]\nurl = \"http://hub2:7333\"\ntoken = \"t\"\nmode = \"sideways\"\n"
  let assert Error(_) = config.parse(raw)
}

pub fn config_peer_requires_url_test() {
  let raw = "[peers.hub2]\ntoken = \"t\"\n"
  let assert Error(_) = config.parse(raw)
}

pub fn config_peer_requires_token_test() {
  let raw = "[peers.hub2]\nurl = \"http://hub2:7333\"\n"
  let assert Error(_) = config.parse(raw)
}

/// Two bridges sharing a name would collide under `UNIQUE(origin,
/// origin_seq)`, so unlike every other default this one cannot be a fixed
/// literal.
pub fn config_bridge_name_test() {
  let assert Ok(default) = config.parse("")
  assert default.bridge_name == host.hostname()

  let assert Ok(named) = config.parse("[bridge]\nname = \"laptop\"\n")
  assert named.bridge_name == "laptop"

  let assert Error(_) = config.parse("[bridge]\nname = \"\"\n")
  let assert Error(_) = config.parse("[bridge]\nname = 7\n")
}

/// Loopback unless explicitly widened: a default that exposed the log to the
/// network would be a security decision made by omission.
pub fn config_bind_test() {
  [#("", "localhost"), #("bind = \"0.0.0.0\"\n", "0.0.0.0")]
  |> list.each(fn(row) {
    let #(raw, expected) = row
    let assert Ok(parsed) = config.parse(raw)
    assert parsed.bind == expected
  })
  let assert Error(_) = config.parse("bind = 7333\n")
}

/// The reason a poll failed has to survive into the whisper: "request failed"
/// for every cause is what made a two-day outage indistinguishable from a
/// dropped keep-alive.
pub fn poller_describe_error_test() {
  [
    #(httpc.ResponseTimeout, "response timed out"),
    #(httpc.InvalidUtf8Response, "response was not utf8"),
    #(
      httpc.FailedToConnect(
        httpc.Posix("econnrefused"),
        httpc.Posix("enetunreach"),
      ),
      "could not connect (ipv4: econnrefused, ipv6: enetunreach)",
    ),
    #(
      httpc.FailedToConnect(
        httpc.TlsAlert("bad_certificate", "expired"),
        httpc.Posix("ehostunreach"),
      ),
      "could not connect (ipv4: tls bad_certificate expired, ipv6: ehostunreach)",
    ),
  ]
  |> list.each(fn(row) {
    let #(error, expected) = row
    assert poller.describe_error(error) == expected
  })
}

pub fn config_rejects_kindless_source_test() {
  let assert Error(_) = config.parse("[sources.x]\nworkspace = \"y\"\n")
}

pub fn from_spec_test() {
  let raw =
    "[sources.work]\nkind = \"bitbucket\"\nworkspace = \"w\"\nrepos = [\"r\"]\ntoken = \"t\"\ntopic_prefix = \"bbs\"\ninterval_seconds = 60\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [spec] = parsed.sources
  let assert Ok(src) = bitbucket.from_spec(spec.name, spec.table)
  assert src.name == "work"
  assert src.interval_ms == 60_000
}

pub fn from_spec_missing_token_test() {
  let raw =
    "[sources.work]\nkind = \"bitbucket\"\nworkspace = \"w\"\nrepos = [\"r\"]\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [spec] = parsed.sources
  let assert Error(_) = bitbucket.from_spec(spec.name, spec.table)
}

/// A wrong-typed key must not be reported as an absent one: `repos = "r"`
/// used to read "missing 'repos'", which sends you looking for the wrong bug.
pub fn from_spec_wrong_typed_repos_test() {
  let raw =
    "[sources.work]\nkind = \"bitbucket\"\nworkspace = \"w\"\nrepos = \"r\"\ntoken = \"t\"\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [spec] = parsed.sources
  let assert Error(message) = bitbucket.from_spec(spec.name, spec.table)
  assert message == "source work: 'repos' should be array, got string"
}

pub fn bitbucket_prs_decoder_test() {
  let fixture =
    "{\"values\":[{\"id\":12,\"title\":\"fix the thing\",\"state\":\"OPEN\",\"updated_on\":\"2026-07-28T10:00:00Z\",\"unrelated\":true}]}"
  let assert Ok([item]) =
    json.parse(from: fixture, using: bitbucket.prs_decoder("api"))
  assert item.id == "12"
  assert item.fingerprint == "OPEN|2026-07-28T10:00:00Z"
  assert item.idem == "12:2026-07-28T10:00:00Z"
  assert item.body
    == "{\"repo\":\"api\",\"id\":12,\"title\":\"fix the thing\",\"state\":\"OPEN\",\"updated_on\":\"2026-07-28T10:00:00Z\"}"
}

pub fn bitbucket_pipelines_decoder_test() {
  let fixture =
    "{\"values\":["
    <> "{\"build_number\":512,\"state\":{\"name\":\"COMPLETED\",\"result\":{\"name\":\"SUCCESSFUL\"}},\"target\":{\"ref_name\":\"main\"}},"
    <> "{\"build_number\":513,\"state\":{\"name\":\"IN_PROGRESS\"},\"target\":{}}"
    <> "]}"
  let assert Ok([done, running]) =
    json.parse(from: fixture, using: bitbucket.pipelines_decoder("api"))
  assert done.id == "512"
  assert done.fingerprint == "COMPLETED|SUCCESSFUL"
  assert done.idem == "512:COMPLETED:SUCCESSFUL"
  assert running.fingerprint == "IN_PROGRESS|"
  assert running.idem == "513:IN_PROGRESS:"
}

pub fn github_prs_decoder_test() {
  let fixture =
    "[{\"number\":7,\"title\":\"add polling\",\"state\":\"open\",\"updated_at\":\"2026-07-28T09:00:00Z\"}]"
  let assert Ok([item]) =
    json.parse(from: fixture, using: github.prs_decoder("tools"))
  assert item.id == "7"
  assert item.fingerprint == "open|2026-07-28T09:00:00Z"
  assert item.idem == "7:2026-07-28T09:00:00Z"
}

pub fn github_runs_decoder_test() {
  let fixture =
    "{\"workflow_runs\":["
    <> "{\"id\":9100000001,\"run_number\":42,\"name\":\"ci\",\"status\":\"completed\",\"conclusion\":\"success\",\"head_branch\":\"main\"},"
    <> "{\"id\":9100000002,\"run_number\":43,\"name\":\"ci\",\"status\":\"in_progress\",\"conclusion\":null,\"head_branch\":null}"
    <> "]}"
  let assert Ok([done, running]) =
    json.parse(from: fixture, using: github.runs_decoder("tools"))
  assert done.id == "9100000001"
  assert done.fingerprint == "completed|success"
  assert done.idem == "9100000001:completed:success"
  assert running.fingerprint == "in_progress|"
  assert running.idem == "9100000002:in_progress:"
}

pub fn gitlab_from_spec_test() {
  let raw =
    "[sources.selfhosted]\nkind = \"gitlab\"\nbase_url = \"https://gitlab.example.com\"\ngroup = \"selfhosted\"\nrepos = [\"app\"]\ntoken = \"t\"\ninterval_seconds = 60\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [spec] = parsed.sources
  let assert Ok(src) = gitlab.from_spec(spec.name, spec.table)
  assert src.name == "selfhosted"
  assert src.interval_ms == 60_000
}

pub fn gitlab_from_spec_missing_group_test() {
  let raw =
    "[sources.selfhosted]\nkind = \"gitlab\"\nrepos = [\"app\"]\ntoken = \"t\"\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [spec] = parsed.sources
  let assert Error(_) = gitlab.from_spec(spec.name, spec.table)
}

pub fn gitlab_mrs_decoder_test() {
  let fixture =
    "[{\"id\":991,\"iid\":14,\"title\":\"wire the thing\",\"state\":\"opened\",\"updated_at\":\"2026-07-28T11:00:00Z\"}]"
  let assert Ok([item]) =
    json.parse(from: fixture, using: gitlab.mrs_decoder("app"))
  assert item.id == "14"
  assert item.fingerprint == "opened|2026-07-28T11:00:00Z"
  assert item.idem == "14:2026-07-28T11:00:00Z"
  assert item.body
    == "{\"repo\":\"app\",\"id\":14,\"title\":\"wire the thing\",\"state\":\"opened\",\"updated_on\":\"2026-07-28T11:00:00Z\"}"
}

pub fn gitlab_pipelines_decoder_test() {
  let fixture =
    "["
    <> "{\"id\":3021,\"status\":\"success\",\"ref\":\"main\"},"
    <> "{\"id\":3022,\"status\":\"running\",\"ref\":null}"
    <> "]"
  let assert Ok([done, running]) =
    json.parse(from: fixture, using: gitlab.pipelines_decoder("app"))
  assert done.id == "3021"
  assert done.fingerprint == "success"
  assert done.idem == "3021:success"
  assert running.fingerprint == "running"
  assert running.idem == "3022:running"
  assert running.body
    == "{\"repo\":\"app\",\"pipeline\":3022,\"state\":\"running\",\"branch\":\"\"}"
}

pub fn config_wrong_type_is_loud_test() {
  let assert Error(_) = config.parse("port = \"7444\"\n")
}

pub fn from_spec_rejects_bad_prefix_test() {
  let raw =
    "[sources.work]\nkind = \"bitbucket\"\nworkspace = \"w\"\nrepos = [\"r\"]\ntoken = \"t\"\ntopic_prefix = \"BB\"\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [spec] = parsed.sources
  let assert Error(_) = bitbucket.from_spec(spec.name, spec.table)
}

pub fn from_spec_rejects_short_interval_test() {
  let raw =
    "[sources.work]\nkind = \"bitbucket\"\nworkspace = \"w\"\nrepos = [\"r\"]\ntoken = \"t\"\ninterval_seconds = 1\n"
  let assert Ok(parsed) = config.parse(raw)
  let assert [spec] = parsed.sources
  let assert Error(_) = bitbucket.from_spec(spec.name, spec.table)
}

fn feed_at(name: String, streak: Int, reason: String) -> health.FeedHealth {
  case streak {
    0 ->
      health.FeedHealth(
        feed: name,
        last_ok_ts: Some(1000),
        consecutive_failures: 0,
        last_error: None,
        last_error_ts: None,
      )
    _ ->
      health.FeedHealth(
        feed: name,
        last_ok_ts: None,
        consecutive_failures: streak,
        last_error: Some(reason),
        last_error_ts: Some(2000),
      )
  }
}

fn feed(name: String, streak: Int) -> health.FeedHealth {
  feed_at(name, streak, "boom")
}

pub fn health_backoff_test() {
  [
    #(0, 30_000),
    #(1, 30_000),
    #(2, 60_000),
    #(3, 120_000),
    #(4, 240_000),
    #(5, 480_000),
    #(6, 900_000),
    #(2941, 900_000),
  ]
  |> list.each(fn(row) {
    let #(streak, expected) = row
    assert health.backoff(30_000, streak, 900_000) == expected
  })
}

pub fn health_state_derivation_test() {
  [
    #([], True, health.Unknown, 0, 0),
    #([#("pr:a", 0), #("run:a", 0)], True, health.Healthy, 0, 2),
    #([#("pr:a", 0), #("run:a", 3)], True, health.Degraded, 0, 1),
    #([#("pr:a", 2), #("run:a", 5)], True, health.Down, 2, 0),
    #([#("pr:a", 0)], False, health.Disabled, 0, 0),
  ]
  |> list.each(fn(row) {
    let #(feeds, enabled, state, streak, ok) = row
    let summary =
      health.summarise(
        "s",
        "github",
        enabled,
        list.map(feeds, fn(spec) { feed(spec.0, spec.1) }),
      )
    assert summary.state == state
    assert summary.down_streak == streak
    assert summary.feeds_ok == ok
  })
}

pub fn health_announces_only_on_change_test() {
  let down = health.summarise("s", "github", True, [feed("pr:a", 1)])
  let still_down = health.summarise("s", "github", True, [feed("pr:a", 2)])
  let healthy = health.summarise("s", "github", True, [feed("pr:a", 0)])

  let assert Some(first) = health.announce(None, down, 9000)
  assert first.kind == "source.down"

  assert health.announce(Some(down), still_down, 9000) == None

  let assert Some(back) = health.announce(Some(still_down), healthy, 9000)
  assert back.kind == "source.recovered"

  assert health.announce(Some(healthy), healthy, 9000) == None
}

/// A different reason is new information even at the same state.
pub fn health_announces_on_changed_reason_test() {
  let unauthorised =
    health.summarise("s", "github", True, [feed_at("pr:a", 1, "status 401")])
  let forbidden =
    health.summarise("s", "github", True, [feed_at("pr:a", 2, "status 403")])
  let assert Some(second) = health.announce(Some(unauthorised), forbidden, 9000)
  assert second.kind == "source.down"
}

/// A source polling cleanly for the first time has not "recovered".
pub fn health_first_clean_poll_is_silent_test() {
  let healthy = health.summarise("s", "github", True, [feed("pr:a", 0)])
  assert health.announce(None, healthy, 9000) == None
}

pub fn store_health_roundtrip_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let failing = [health.Reached("pr:a"), health.Unreachable("run:a", "401")]

  let assert Ok(Nil) = store.record_poll(conn, "gh", failing, 1000)
  let assert Ok([pr, run]) = store.read_source_health(conn, "gh")
  assert pr.last_ok_ts == Some(1000)
  assert pr.consecutive_failures == 0
  assert run.consecutive_failures == 1
  assert run.last_error == Some("401")

  let assert Ok(Nil) = store.record_poll(conn, "gh", failing, 2000)
  let assert Ok([_, twice]) = store.read_source_health(conn, "gh")
  assert twice.consecutive_failures == 2

  let assert Ok(Nil) =
    store.record_poll(
      conn,
      "gh",
      [health.Reached("pr:a"), health.Reached("run:a")],
      3000,
    )
  let assert Ok([_, recovered]) = store.read_source_health(conn, "gh")
  assert recovered.consecutive_failures == 0
  assert recovered.last_error == None
}

pub fn store_health_prunes_stale_feeds_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(Nil) =
    store.record_poll(
      conn,
      "gh",
      [health.Reached("pr:a"), health.Reached("pr:b")],
      1000,
    )
  let assert Ok(both) = store.read_source_health(conn, "gh")
  assert list.length(both) == 2

  let assert Ok(Nil) =
    store.record_poll(conn, "gh", [health.Reached("pr:a")], 2000)
  let assert Ok([only]) = store.read_source_health(conn, "gh")
  assert only.feed == "pr:a"
}

pub fn store_health_prunes_removed_sources_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(Nil) =
    store.record_poll(conn, "gone", [health.Reached("pr:a")], 1000)
  let assert Ok(Nil) = store.prune_sources(conn, ["still-here"])
  let assert Ok([]) = store.read_source_health(conn, "gone")
}

pub fn hub_record_poll_whispers_transitions_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(started) = hub.start(conn, "hub1")
  let h = started.data
  process.send(h, hub.SetRoster([health.Registration("gh", "github", True)]))

  let inbox = process.new_subject()
  process.send(h, hub.Subscribe("reeds.source", 0, inbox))

  let failing = [health.Unreachable("pr:a", "status 401")]

  let assert 1 =
    process.call(h, waiting: 1000, sending: hub.RecordPoll("gh", failing, _))
  let assert Ok(first) = process.receive(inbox, 1000)
  assert first.kind == "source.down"
  assert first.idem == Some("gh:down")

  // Identical failure: the streak climbs, the network stays quiet. A second
  // bridge observing the same transition would compute the same idem, so
  // this also exercises that a repeat never gets a second local seq.
  let assert 2 =
    process.call(h, waiting: 1000, sending: hub.RecordPoll("gh", failing, _))
  let assert Error(_) = process.receive(inbox, 100)

  let assert 0 =
    process.call(h, waiting: 1000, sending: hub.RecordPoll(
      "gh",
      [health.Reached("pr:a")],
      _,
    ))
  let assert Ok(back) = process.receive(inbox, 1000)
  assert back.kind == "source.recovered"
}

/// The report comes from the roster, so a configured source is never simply
/// absent from it.
pub fn hub_health_reports_roster_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(started) = hub.start(conn, "hub1")
  let h = started.data
  process.send(
    h,
    hub.SetRoster([
      health.Registration("gh", "github", True),
      health.Registration("parked", "bitbucket", False),
    ]),
  )

  let assert Ok(sources) = process.call(h, waiting: 1000, sending: hub.Health)
  let assert [gh, parked] = sources
  assert gh.state == health.Unknown
  assert parked.state == health.Disabled
  assert health.all_ok(sources)

  let assert 1 =
    process.call(h, waiting: 1000, sending: hub.RecordPoll(
      "gh",
      [health.Unreachable("pr:a", "status 401")],
      _,
    ))
  let assert Ok(down) = process.call(h, waiting: 1000, sending: hub.Health)
  assert !health.all_ok(down)
}

pub fn hub_publish_subscribe_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(started) = hub.start(conn, "hub1")
  let h = started.data

  let assert Ok(1) =
    process.call(h, waiting: 1000, sending: hub.Publish(
      "bb.pr.x.1",
      "t",
      "note",
      "{\"n\":1}",
      None,
      _,
    ))

  let inbox = process.new_subject()
  process.send(h, hub.Subscribe("bb.pr", 0, inbox))

  let assert Ok(replayed) = process.receive(inbox, 1000)
  assert replayed.seq == 1

  let assert Ok(2) =
    process.call(h, waiting: 1000, sending: hub.Publish(
      "bb.pr.x.1",
      "t",
      "note",
      "{\"n\":2}",
      None,
      _,
    ))
  let assert Ok(live) = process.receive(inbox, 1000)
  assert live.seq == 2

  let assert Ok(3) =
    process.call(h, waiting: 1000, sending: hub.Publish(
      "other.topic",
      "t",
      "note",
      "{}",
      None,
      _,
    ))
  let assert Error(Nil) = process.receive(inbox, 100)

  let assert Ok(all) =
    process.call(h, waiting: 1000, sending: hub.ReadSince("*", 0, 10, _))
  assert list.length(all) == 3
}

pub fn hub_peer_cursor_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(started) = hub.start(conn, "hub1")
  let h = started.data

  let assert 0 =
    process.call(h, waiting: 1000, sending: hub.GetPeerCursor("hub2", _))
  process.send(h, hub.PutPeerCursor("hub2", 7))
  let assert 7 =
    process.call(h, waiting: 1000, sending: hub.GetPeerCursor("hub2", _))
}

/// Foreign ingest preserves origin/origin_seq/idem verbatim, fans out to
/// subscribers with a freshly assigned local seq, and a re-ingested batch
/// (as a resumed pull would send) counts zero new rows without erroring.
pub fn hub_ingest_foreign_test() {
  let assert Ok(conn) = store.open(":memory:", origin: "hub1")
  let assert Ok(started) = hub.start(conn, "hub1")
  let h = started.data

  let inbox = process.new_subject()
  process.send(h, hub.Subscribe("*", 0, inbox))

  let foreign =
    Whisper(
      seq: 0,
      topic: "gl.mr.app.14",
      ts: 5,
      sender: "gl",
      kind: "mr.seen",
      body: "{}",
      origin: "hub2",
      origin_seq: 9,
      idem: Some("14:2026-07-28T11:00:00Z"),
    )

  let assert Ok(1) =
    process.call(h, waiting: 1000, sending: hub.IngestForeign([foreign], _))
  let assert Ok(fanned) = process.receive(inbox, 1000)
  assert fanned.origin == "hub2"
  assert fanned.origin_seq == 9
  assert fanned.seq == 1

  // A resumed pull re-sends the same whisper: dedup no-ops it, and it must
  // never round-trip back onto a live subscriber a second time.
  let assert Ok(0) =
    process.call(h, waiting: 1000, sending: hub.IngestForeign([foreign], _))
  let assert Error(Nil) = process.receive(inbox, 100)
}

/// Starts a real bridge (store + hub + mist listener bound to an
/// OS-assigned port) so the pull loop tests exercise the actual `/t/*` HTTP
/// round trip, not just the hub's internal message passing.
fn start_bridge(origin: String) -> #(process.Subject(hub.Msg), Int) {
  let assert Ok(conn) = store.open(":memory:", origin:)
  let assert Ok(started) = hub.start(conn, origin)
  let hub_subject = started.data

  let port_subject = process.new_subject()
  let builder =
    mist.new(api.handler(hub_subject, []))
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _ip) {
      process.send(port_subject, port)
    })
  let assert Ok(_) = mist.start(builder)
  let assert Ok(port) = process.receive(port_subject, 2000)
  #(hub_subject, port)
}

fn pull_peer(name: String, port: Int) -> config.PeerSpec {
  config.PeerSpec(
    name:,
    url: "http://127.0.0.1:" <> int.to_string(port),
    token: "",
    mode: config.Pull,
    interval_ms: 60_000,
    backoff_cap_ms: 900_000,
  )
}

/// End-to-end proof of the Phase 3 done-criteria over a real HTTP round
/// trip: two bridges converge, a peer restarted from its persisted cursor
/// picks up only what it is missing, and a whisper pulled back to its own
/// origin never duplicates.
pub fn peer_pull_converges_and_never_round_trips_test() {
  let #(hub1, port1) = start_bridge("hub1")
  let #(hub2, port2) = start_bridge("hub2")

  let assert Ok(1) =
    process.call(hub1, waiting: 1000, sending: hub.Publish(
      "agents.turtle",
      "turtle",
      "note",
      "{\"n\":1}",
      None,
      _,
    ))

  let inbox2 = process.new_subject()
  process.send(hub2, hub.Subscribe("*", 0, inbox2))

  // hub2 pulls from hub1: a fresh actor ticks once immediately on start.
  let assert Ok(started1) = peer.start(pull_peer("hub1", port1), hub2)

  let assert Ok(pulled) = process.receive(inbox2, 3000)
  assert pulled.topic == "agents.turtle"
  assert pulled.origin == "hub1"
  assert pulled.origin_seq == 1

  let assert Ok([only]) =
    process.call(hub2, waiting: 1000, sending: hub.ReadSince("*", 0, 10, _))
  assert only.origin == "hub1"

  // Kill and resume: `started1`'s actor is left running but its next tick is
  // 60s away, so it will not interfere. A fresh actor (standing in for a
  // supervisor restart after a crash) must resume from the cursor persisted
  // in hub2's own store rather than from process memory: it should pick up
  // only the new whisper, never re-fetch or re-ingest the first one.
  let _ = started1
  let assert Ok(_) =
    process.call(hub1, waiting: 1000, sending: hub.Publish(
      "agents.turtle2",
      "turtle",
      "note",
      "{\"n\":2}",
      None,
      _,
    ))
  let assert Ok(_) = peer.start(pull_peer("hub1", port1), hub2)

  let assert Ok(resumed) = process.receive(inbox2, 3000)
  assert resumed.topic == "agents.turtle2"
  assert resumed.origin == "hub1"
  assert resumed.origin_seq == 2

  let assert Ok(after_resume) =
    process.call(hub2, waiting: 1000, sending: hub.ReadSince("*", 0, 10, _))
  assert list.length(after_resume) == 2

  // Never round-trips: hub1 now pulls from hub2, which holds hub1's own
  // whispers tagged origin="hub1". Ingesting them back must be a no-op, so
  // hub1's log gains nothing for facts it already originated.
  let assert Ok(_) = peer.start(pull_peer("hub2", port2), hub1)
  process.sleep(500)
  let assert Ok(hub1_rows) =
    process.call(hub1, waiting: 1000, sending: hub.ReadSince("*", 0, 10, _))
  assert list.length(hub1_rows) == 2
}

/// POST /ingest accepts a since-response-shaped batch, dedups on each
/// whisper's own (origin, origin_seq), assigns local seqs, and reports the
/// per-origin high-water mark so a pusher can advance without a read
/// round-trip.
pub fn ingest_route_test() {
  let #(hub, port) = start_bridge("hub1")
  let whispers = [
    Whisper(
      seq: 9,
      topic: "gh.pr.tools.7",
      ts: 100,
      sender: "gh",
      kind: "pr.seen",
      body: "{\"a\":1}",
      origin: "hub2",
      origin_seq: 5,
      idem: Some("7:2026-07-28T09:00:00Z"),
    ),
    Whisper(
      seq: 10,
      topic: "agents.turtle",
      ts: 200,
      sender: "turtle",
      kind: "note",
      body: "{\"msg\":\"carry on\"}",
      origin: "hub2",
      origin_seq: 6,
      idem: None,
    ),
  ]
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/ingest")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_body(since_envelope(whispers, 6, False))

  let assert Ok(resp) = httpc.send(req)
  assert resp.status == 200
  assert resp.body == "{\"accepted\":2,\"cursors\":{\"hub2\":6}}"

  let assert Ok(stored) =
    process.call(hub, waiting: 1000, sending: hub.ReadSince("*", 0, 10, _))
  assert list.length(stored) == 2

  // Resending the same batch is a dedup no-op: accepted drops to 0, but the
  // cursor still reports 6 since that origin_seq really was received.
  let assert Ok(resp2) = httpc.send(req)
  assert resp2.body == "{\"accepted\":0,\"cursors\":{\"hub2\":6}}"
}

pub fn ingest_route_rejects_malformed_body_test() {
  let #(_hub, port) = start_bridge("hub1")
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/ingest")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_body("not json")
  let assert Ok(resp) = httpc.send(req)
  assert resp.status == 400
}

@external(erlang, "reeds_rescue_ffi", "rescue")
fn rescue(thunk: fn() -> a) -> Result(a, String)

@external(erlang, "erlang", "error")
fn raise(reason: String) -> a

pub fn rescue_passes_a_value_through_test() {
  assert rescue(fn() { 42 }) == Ok(42)
}

pub fn is_loopback_ip_test() {
  [
    #(mist.IpV4(127, 0, 0, 1), True),
    #(mist.IpV4(127, 1, 2, 3), True),
    #(mist.IpV4(10, 0, 0, 5), False),
    #(mist.IpV4(192, 168, 1, 1), False),
    #(mist.IpV6(0, 0, 0, 0, 0, 0, 0, 1), True),
    #(mist.IpV6(0xfe80, 0, 0, 0, 0, 0, 0, 1), False),
  ]
  |> list.each(fn(row) {
    let #(ip, expected) = row
    assert api.is_loopback_ip(ip) == expected
  })
}

/// The token has to come from a scheme-prefixed `Authorization` header, not
/// from bare presence of the right string somewhere in it.
pub fn valid_bearer_test() {
  let tokens = ["peer-a-token", "peer-b-token"]
  [
    #(Ok("Bearer peer-a-token"), True),
    #(Ok("Bearer peer-b-token"), True),
    #(Ok("Bearer wrong-token"), False),
    #(Ok("bearer peer-a-token"), False),
    #(Ok("peer-a-token"), False),
    #(Ok(""), False),
    #(Error(Nil), False),
  ]
  |> list.each(fn(row) {
    let #(header, expected) = row
    assert api.valid_bearer(header, tokens) == expected
  })
}

pub fn valid_bearer_rejects_all_when_no_peers_configured_test() {
  assert api.valid_bearer(Ok("Bearer anything"), []) == False
}

pub fn rescue_turns_a_raise_into_an_error_test() {
  let assert Error(detail) = rescue(fn() { raise("socket_closed_remotely") })
  assert string.contains(detail, "socket_closed_remotely")
}
