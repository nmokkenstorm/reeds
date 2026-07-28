import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import reeds/hub
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
