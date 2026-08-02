import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import reeds/config
import reeds/hub
import reeds/sources/bitbucket
import reeds/sources/github
import reeds/sources/gitlab
import reeds/store
import reeds/whisper.{Whisper}

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
    )
  assert whisper.to_json_string(w)
    == "{\"seq\":7,\"topic\":\"a.b\",\"ts\":123,\"sender\":\"turtle\",\"kind\":\"note\",\"body\":{\"msg\":\"carry on\"}}"
}

pub fn store_roundtrip_test() {
  let assert Ok(conn) = store.open(":memory:")
  let assert Ok(1) =
    store.append(
      conn,
      topic: "a.b",
      ts: 1,
      sender: "t",
      kind: "note",
      body: "{}",
    )
  let assert Ok(2) =
    store.append(
      conn,
      topic: "a.c",
      ts: 2,
      sender: "t",
      kind: "note",
      body: "{}",
    )
  let assert Ok(3) =
    store.append(
      conn,
      topic: "ax",
      ts: 3,
      sender: "t",
      kind: "note",
      body: "{}",
    )

  let assert Ok([one, two]) =
    store.read_since(conn, prefix: "a", since: 0, limit: 10)
  assert one.topic == "a.b"
  assert two.topic == "a.c"

  let assert Ok([only]) =
    store.read_since(conn, prefix: "*", since: 2, limit: 10)
  assert only.topic == "ax"

  let assert Ok([]) =
    store.read_since(conn, prefix: "nope", since: 0, limit: 10)
}

pub fn store_rejects_invalid_json_test() {
  let assert Ok(conn) = store.open(":memory:")
  let assert Error(_) =
    store.append(
      conn,
      topic: "a",
      ts: 1,
      sender: "t",
      kind: "note",
      body: "not json",
    )
}

pub fn source_state_test() {
  let assert Ok(conn) = store.open(":memory:")
  let assert Ok(None) = store.get_source_state(conn, "bitbucket")
  let assert Ok(Nil) =
    store.put_source_state(conn, "bitbucket", "{\"a\":\"1\"}")
  let assert Ok(Nil) =
    store.put_source_state(conn, "bitbucket", "{\"a\":\"2\"}")
  let assert Ok(Some("{\"a\":\"2\"}")) =
    store.get_source_state(conn, "bitbucket")
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
  assert parsed == config.Config(port: 7333, db: "reeds.db", sources: [])
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

pub fn bitbucket_prs_decoder_test() {
  let fixture =
    "{\"values\":[{\"id\":12,\"title\":\"fix the thing\",\"state\":\"OPEN\",\"updated_on\":\"2026-07-28T10:00:00Z\",\"unrelated\":true}]}"
  let assert Ok([item]) =
    json.parse(from: fixture, using: bitbucket.prs_decoder("api"))
  assert item.id == "12"
  assert item.fingerprint == "OPEN|2026-07-28T10:00:00Z"
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
  assert running.fingerprint == "IN_PROGRESS|"
}

pub fn github_prs_decoder_test() {
  let fixture =
    "[{\"number\":7,\"title\":\"add polling\",\"state\":\"open\",\"updated_at\":\"2026-07-28T09:00:00Z\"}]"
  let assert Ok([item]) =
    json.parse(from: fixture, using: github.prs_decoder("tools"))
  assert item.id == "7"
  assert item.fingerprint == "open|2026-07-28T09:00:00Z"
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
  assert running.fingerprint == "in_progress|"
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
  assert running.fingerprint == "running"
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

pub fn hub_publish_subscribe_test() {
  let assert Ok(conn) = store.open(":memory:")
  let assert Ok(started) = hub.start(conn)
  let h = started.data

  let assert Ok(1) =
    process.call(h, waiting: 1000, sending: hub.Publish(
      "bb.pr.x.1",
      "t",
      "note",
      "{\"n\":1}",
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
      _,
    ))
  let assert Error(Nil) = process.receive(inbox, 100)

  let assert Ok(all) =
    process.call(h, waiting: 1000, sending: hub.ReadSince("*", 0, 10, _))
  assert list.length(all) == 3
}

@external(erlang, "reeds_rescue_ffi", "rescue")
fn rescue(thunk: fn() -> a) -> Result(a, String)

@external(erlang, "erlang", "error")
fn raise(reason: String) -> a

pub fn rescue_passes_a_value_through_test() {
  assert rescue(fn() { 42 }) == Ok(42)
}

pub fn rescue_turns_a_raise_into_an_error_test() {
  let assert Error(detail) = rescue(fn() { raise("socket_closed_remotely") })
  assert string.contains(detail, "socket_closed_remotely")
}
