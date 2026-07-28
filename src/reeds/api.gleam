import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string_tree
import mist.{type Connection, type ResponseData}
import reeds/hub
import reeds/whisper.{type Whisper}

const max_body = 1_048_576

const max_page = 1000

pub fn handler(
  hub: Subject(hub.Msg),
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(req) {
    case request.path_segments(req), req.method {
      ["health"], Get -> json_response(200, "{\"ok\":true}")
      ["t", topic], Post -> publish(hub, req, topic)
      ["t", prefix], Get -> read_since(hub, req, prefix)
      ["t", prefix, "events"], Get -> sse(hub, req, prefix)
      _, _ -> json_response(404, "{\"error\":\"not found\"}")
    }
  }
}

fn publish(
  hub: Subject(hub.Msg),
  req: Request(Connection),
  topic: String,
) -> Response(ResponseData) {
  case whisper.valid_topic(topic) {
    False -> error_response(400, "invalid topic: " <> topic)
    True -> {
      let sender =
        request.get_header(req, "x-reeds-sender") |> result.unwrap("anon")
      let kind =
        request.get_header(req, "x-reeds-kind") |> result.unwrap("note")
      let body =
        mist.read_body(req, max_body_limit: max_body)
        |> result.replace_error("unreadable body")
        |> result.try(fn(read) {
          bit_array.to_string(read.body)
          |> result.replace_error("body is not utf8")
        })
        |> result.try(fn(text) {
          json.parse(from: text, using: decode.dynamic)
          |> result.replace_error("body is not valid json")
          |> result.replace(text)
        })
      case body {
        Error(reason) -> error_response(400, reason)
        Ok(body) ->
          case
            process.call(hub, waiting: 5000, sending: hub.Publish(
              topic,
              sender,
              kind,
              body,
              _,
            ))
          {
            Error(reason) -> error_response(500, reason)
            Ok(seq) ->
              json_response(201, "{\"seq\":" <> int.to_string(seq) <> "}")
          }
      }
    }
  }
}

fn read_since(
  hub: Subject(hub.Msg),
  req: Request(Connection),
  prefix: String,
) -> Response(ResponseData) {
  let since = query_int(req, "since", 0)
  let limit = int.min(query_int(req, "limit", 200), max_page)
  case
    process.call(hub, waiting: 5000, sending: hub.ReadSince(
      prefix,
      since,
      limit,
      _,
    ))
  {
    Error(reason) -> error_response(500, reason)
    Ok(whispers) -> {
      let next =
        whispers
        |> list.last
        |> result.map(fn(w) { w.seq })
        |> result.unwrap(since)
      json_response(
        200,
        "{\"whispers\":"
          <> whisper.list_to_json_string(whispers)
          <> ",\"next_since\":"
          <> int.to_string(next)
          <> ",\"more\":"
          <> more_json(list.length(whispers) == limit)
          <> "}",
      )
    }
  }
}

fn sse(
  hub: Subject(hub.Msg),
  req: Request(Connection),
  prefix: String,
) -> Response(ResponseData) {
  let since = case request.get_header(req, "last-event-id") {
    Ok(id) -> int.parse(id) |> result.unwrap(0)
    Error(_) -> query_int(req, "since", 0)
  }
  mist.server_sent_events(
    request: req,
    initial_response: response.new(200),
    init: fn(subject) {
      process.send(hub, hub.Subscribe(prefix, since, subject))
      Nil
    },
    loop: fn(state, whisper: Whisper, conn) {
      let event =
        whisper.to_json_string(whisper)
        |> string_tree.from_string
        |> mist.event
        |> mist.event_id(int.to_string(whisper.seq))
      case mist.send_event(conn, event) {
        Ok(_) -> actor.continue(state)
        Error(_) -> actor.stop()
      }
    },
  )
}

fn query_int(req: Request(Connection), name: String, default: Int) -> Int {
  request.get_query(req)
  |> result.unwrap([])
  |> list.key_find(name)
  |> result.try(int.parse)
  |> result.unwrap(default)
}

fn more_json(more: Bool) -> String {
  case more {
    True -> "true"
    False -> "false"
  }
}

fn json_response(status: Int, body: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn error_response(status: Int, reason: String) -> Response(ResponseData) {
  json_response(
    status,
    json.to_string(json.object([#("error", json.string(reason))])),
  )
}
