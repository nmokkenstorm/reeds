import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import mist.{type Connection, type ResponseData}
import reeds/dashboard
import reeds/health as health_module
import reeds/hub
import reeds/state
import reeds/whisper.{type Whisper}
import reeds/wire

const max_body = 1_048_576

/// Double the publish limit: a pushed whisper wraps a publish-limit body in
/// its envelope, so `/ingest` must accept more than `POST /t/:topic` or a
/// maximum legal whisper could never replicate.
const max_ingest_body = 2_097_152

const max_page = 1000

/// Loopback requests are unauthenticated; anything else must carry a
/// `Bearer` token matching a configured peer. Checked ahead of routing, so
/// no route can be reached by accident.
pub fn handler(
  hub: Subject(hub.Msg),
  peer_tokens: List(String),
) -> fn(Request(Connection)) -> Response(ResponseData) {
  fn(req) {
    case authorized(req, peer_tokens) {
      False -> error_response(401, "unauthorized")
      True ->
        case request.path_segments(req), req.method {
          ["health"], Get -> health(hub)
          ["t", topic], Post -> publish(hub, req, topic)
          ["t", prefix], Get -> read_since(hub, req, prefix)
          ["t", prefix, "events"], Get -> sse(hub, req, prefix)
          ["ingest"], Post -> ingest(hub, req)
          ["state"], Get -> get_state(hub, req)
          ["dashboard"], Get -> dashboard_page()
          _, _ -> json_response(404, "{\"error\":\"not found\"}")
        }
    }
  }
}

fn authorized(req: Request(Connection), peer_tokens: List(String)) -> Bool {
  let loopback = case mist.get_connection_info(req.body) {
    Ok(info) -> is_loopback_ip(info.ip_address)
    Error(_) -> False
  }
  loopback
  || valid_bearer(request.get_header(req, "authorization"), peer_tokens)
}

/// 127.0.0.0/8 and the IPv6 loopback `::1`; nothing else counts, so a
/// misconfigured reverse proxy on the same box cannot silently skip auth.
pub fn is_loopback_ip(ip: mist.IpAddress) -> Bool {
  case ip {
    mist.IpV4(127, _, _, _) -> True
    mist.IpV6(0, 0, 0, 0, 0, 0, 0, 1) -> True
    _ -> False
  }
}

pub fn valid_bearer(
  header: Result(String, Nil),
  peer_tokens: List(String),
) -> Bool {
  case header {
    Error(_) -> False
    Ok(value) ->
      case string.split_once(value, on: " ") {
        Ok(#("Bearer", token)) ->
          token != "" && list.contains(peer_tokens, token)
        _ -> False
      }
  }
}

/// 200 with `ok: false` rather than 5xx when a source is down: the daemon is
/// answering correctly, it is the upstream that is broken, and a transport
/// error would tell a caller the wrong thing.
fn health(hub_subject: Subject(hub.Msg)) -> Response(ResponseData) {
  case process.call(hub_subject, waiting: 5000, sending: hub.Health) {
    Error(reason) -> error_response(500, reason)
    Ok(sources) -> json_response(200, health_module.to_json(sources))
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
              option.None,
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
  let limit = int.clamp(query_int(req, "limit", 200), min: 1, max: max_page)
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

/// Receiving side of a peer push: body is a `/t/*?since=N` response verbatim
/// (the same wire shape `wire.parse_since_response` already reads for the
/// pull loop), so a pusher can forward its own read of `read_since` without
/// reshaping it. `next_since`/`more` are the pusher's own cursor bookkeeping
/// and irrelevant here. `cursors` is computed from the batch itself, not
/// from `IngestForeign`'s accepted count, since a dedup no-op still confirms
/// its origin_seq was received.
fn ingest(
  hub: Subject(hub.Msg),
  req: Request(Connection),
) -> Response(ResponseData) {
  let parsed =
    mist.read_body(req, max_body_limit: max_ingest_body)
    |> result.replace_error("unreadable body")
    |> result.try(fn(read) {
      bit_array.to_string(read.body)
      |> result.replace_error("body is not utf8")
    })
    |> result.try(wire.parse_since_response)
  case parsed {
    Error(reason) -> error_response(400, reason)
    Ok(#(whispers, _next_since, _more)) ->
      case
        process.call(hub, waiting: 5000, sending: hub.IngestForeign(whispers, _))
      {
        Error(reason) -> error_response(500, reason)
        Ok(accepted) ->
          json_response(
            200,
            "{\"accepted\":"
              <> int.to_string(accepted)
              <> ",\"cursors\":"
              <> cursors_json(whispers)
              <> "}",
          )
      }
  }
}

/// The highest `origin_seq` seen per origin in this batch, whether or not
/// the whisper turned out to be a dedup no-op: a duplicate still confirms
/// the pusher's cursor is caught up to that point.
fn cursors_json(whispers: List(Whisper)) -> String {
  whispers
  |> list.fold(dict.new(), fn(cursors, w) {
    dict.upsert(cursors, w.origin, fn(existing) {
      case existing {
        Some(seq) if seq >= w.origin_seq -> seq
        _ -> w.origin_seq
      }
    })
  })
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, json.int(pair.1)) })
  |> json.object
  |> json.to_string
}

fn get_state(
  hub: Subject(hub.Msg),
  req: Request(Connection),
) -> Response(ResponseData) {
  let prefix = query_string(req, "prefix", "*")
  case process.call(hub, waiting: 5000, sending: hub.ReadState(prefix, _)) {
    Error(reason) -> error_response(500, reason)
    Ok(entries) ->
      json_response(
        200,
        "{\"entries\":" <> state.list_to_json_string(entries) <> "}",
      )
  }
}

fn dashboard_page() -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(dashboard.page())))
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

fn query_string(
  req: Request(Connection),
  name: String,
  default: String,
) -> String {
  request.get_query(req)
  |> result.unwrap([])
  |> list.key_find(name)
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
