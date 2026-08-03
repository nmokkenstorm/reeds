import envoy
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import reeds/host
import reeds/whisper
import simplifile
import tom.{type Toml}

pub type Config {
  Config(
    port: Int,
    bind: String,
    db: String,
    bridge_name: String,
    sources: List(SourceSpec),
  )
}

pub type SourceSpec {
  SourceSpec(
    name: String,
    kind: String,
    enabled: Bool,
    table: Dict(String, Toml),
  )
}

/// A table plus the context every error it produces is labelled with, so a
/// source module cannot mislabel its own failures or forget the prefix.
pub opaque type Reader {
  Reader(table: Dict(String, Toml), context: String)
}

pub fn source_reader(name: String, table: Dict(String, Toml)) -> Reader {
  Reader(table:, context: "source " <> name)
}

/// Load config from a TOML file. Only a genuinely absent file yields the
/// defaults; unreadable or malformed config is an error, so a permission
/// mishap cannot silently boot a daemon with zero sources.
pub fn load(path: String) -> Result(Config, String) {
  case simplifile.read(path) {
    Ok(raw) -> parse(raw)
    Error(simplifile.Enoent) -> parse("")
    Error(error) -> Error(path <> ": " <> simplifile.describe_error(error))
  }
}

/// Parse a TOML config document; exported for tests.
pub fn parse(raw: String) -> Result(Config, String) {
  use toml <- result.try(
    tom.parse(raw) |> result.replace_error("config is not valid toml"),
  )
  let root = Reader(table: toml, context: "config")
  use port <- result.try(optional_int(root, "port", 7333))
  // Loopback by default: the log is unauthenticated, so a bind address is an
  // explicit decision, never something a default quietly makes for you.
  use bind <- result.try(optional_string(root, "bind", "localhost"))
  use db <- result.try(optional_string(root, "db", "reeds.db"))
  use bridge_name <- result.try(bridge_name(toml))
  use sources <- result.try(sources(toml))
  Ok(Config(port:, bind:, db:, bridge_name:, sources:))
}

/// The origin name this bridge stamps on its own whispers. Explicit
/// `[bridge] name`, or this host's hostname: unlike every other default here,
/// it cannot be a fixed literal, since two bridges sharing one would collide
/// under `UNIQUE(origin, origin_seq)`.
fn bridge_name(toml: Dict(String, Toml)) -> Result(String, String) {
  case tom.get_string(toml, ["bridge", "name"]) {
    Ok("") -> Error("config: 'bridge.name' is empty")
    Ok(name) -> Ok(name)
    Error(tom.NotFound(_)) -> Ok(host.hostname())
    Error(tom.WrongType(_, expected, got)) ->
      Error(
        "config: 'bridge.name' should be "
        <> string.lowercase(expected)
        <> ", got "
        <> string.lowercase(got),
      )
  }
}

fn sources(toml: Dict(String, Toml)) -> Result(List(SourceSpec), String) {
  case tom.get_table(toml, ["sources"]) {
    Error(_) -> Ok([])
    Ok(tables) ->
      tables
      |> dict.to_list
      |> list.try_map(fn(entry) {
        let #(name, value) = entry
        use _ <- result.try(instance_name(name))
        case value {
          tom.Table(table) | tom.InlineTable(table) -> {
            let reader = source_reader(name, table)
            use kind <- result.try(required_string(reader, "kind"))
            use enabled <- result.try(optional_bool(reader, "enabled", True))
            Ok(SourceSpec(name:, kind:, enabled:, table:))
          }
          _ -> Error("source " <> name <> ": not a table")
        }
      })
  }
}

fn instance_name(name: String) -> Result(Nil, String) {
  case whisper.valid_topic(name) {
    True -> Ok(Nil)
    False ->
      Error("source " <> name <> ": name must be lowercase [a-z0-9_-] segments")
  }
}

/// Every typed read goes through here, so one function decides what an
/// absent key and a wrong-typed key each mean: absent is None, wrong-typed
/// is always an error. `port = "7444"` cannot silently mean 7333.
fn lookup(
  reader: Reader,
  get: fn(Dict(String, Toml), List(String)) -> Result(a, tom.GetError),
  key: String,
) -> Result(Option(a), String) {
  case get(reader.table, [key]) {
    Ok(value) -> Ok(Some(value))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(_, expected, got)) ->
      Error(problem(
        reader,
        key,
        "should be "
          <> string.lowercase(expected)
          <> ", got "
          <> string.lowercase(got),
      ))
  }
}

fn problem(reader: Reader, key: String, complaint: String) -> String {
  reader.context <> ": '" <> key <> "' " <> complaint
}

fn missing(reader: Reader, key: String) -> String {
  reader.context <> ": missing '" <> key <> "'"
}

/// Helpers for source modules reading their `[sources.<name>]` table.
pub fn required_string(reader: Reader, key: String) -> Result(String, String) {
  use found <- result.try(lookup(reader, tom.get_string, key))
  case found {
    Some("") -> Error(problem(reader, key, "is empty"))
    Some(value) -> Ok(value)
    None -> Error(missing(reader, key))
  }
}

pub fn optional_string(
  reader: Reader,
  key: String,
  default: String,
) -> Result(String, String) {
  lookup(reader, tom.get_string, key)
  |> result.map(option.unwrap(_, default))
}

pub fn optional_int(
  reader: Reader,
  key: String,
  default: Int,
) -> Result(Int, String) {
  lookup(reader, tom.get_int, key) |> result.map(option.unwrap(_, default))
}

pub fn optional_bool(
  reader: Reader,
  key: String,
  default: Bool,
) -> Result(Bool, String) {
  lookup(reader, tom.get_bool, key) |> result.map(option.unwrap(_, default))
}

pub fn maybe_string(
  reader: Reader,
  key: String,
) -> Result(Option(String), String) {
  lookup(reader, tom.get_string, key)
}

pub fn string_list(
  reader: Reader,
  key: String,
) -> Result(List(String), String) {
  use found <- result.try(lookup(reader, tom.get_array, key))
  case found {
    None -> Error(missing(reader, key))
    Some(items) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(value) -> Ok(value)
          _ -> Error(problem(reader, key, "must be strings"))
        }
      })
  }
}

/// Token from `token`, or the environment variable named by `token_env`.
pub fn token(reader: Reader) -> Result(String, String) {
  use direct <- result.try(lookup(reader, tom.get_string, "token"))
  case direct {
    Some("") -> Error(problem(reader, "token", "is empty"))
    Some(value) -> Ok(value)
    None -> {
      use named <- result.try(lookup(reader, tom.get_string, "token_env"))
      use var <- result.try(option.to_result(
        named,
        reader.context <> ": missing 'token' or 'token_env'",
      ))
      case envoy.get(var) {
        Ok(value) if value != "" -> Ok(value)
        _ -> Error(reader.context <> ": env " <> var <> " not set")
      }
    }
  }
}

/// Poll interval in milliseconds, default 30s, minimum 5s: a sub-second
/// interval is a config error, not an aggressive preference.
pub fn interval_ms(reader: Reader) -> Result(Int, String) {
  use seconds <- result.try(optional_int(reader, "interval_seconds", 30))
  case seconds >= 5 {
    True -> Ok(seconds * 1000)
    False -> Error(problem(reader, "interval_seconds", "must be at least 5"))
  }
}

/// Ceiling for the exponential backoff applied while every feed of a source
/// is failing, default 15m. Rejected below the poll interval, since a cap
/// under the base would make "backing off" poll faster than normal.
pub fn backoff_cap_ms(reader: Reader, interval_ms: Int) -> Result(Int, String) {
  use seconds <- result.try(optional_int(reader, "backoff_cap_seconds", 900))
  case seconds * 1000 >= interval_ms {
    True -> Ok(seconds * 1000)
    False ->
      Error(problem(
        reader,
        "backoff_cap_seconds",
        "must be at least 'interval_seconds'",
      ))
  }
}

/// Topic prefix, validated so a typo fails at boot rather than as an
/// endless stream of hub rejections.
pub fn topic_prefix(reader: Reader, default: String) -> Result(String, String) {
  use prefix <- result.try(optional_string(reader, "topic_prefix", default))
  case whisper.valid_topic(prefix) {
    True -> Ok(prefix)
    False ->
      Error(problem(reader, "topic_prefix", "is not a valid topic prefix"))
  }
}
