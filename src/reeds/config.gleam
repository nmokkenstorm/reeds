import envoy
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import reeds/whisper
import simplifile
import tom.{type Toml}

pub type Config {
  Config(port: Int, db: String, sources: List(SourceSpec))
}

pub type SourceSpec {
  SourceSpec(name: String, kind: String, table: Dict(String, Toml))
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
  use port <- result.try(optional_int(toml, "port", 7333, "config"))
  use db <- result.try(optional_string(toml, "db", "reeds.db", "config"))
  use sources <- result.try(sources(toml))
  Ok(Config(port:, db:, sources:))
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
          tom.Table(table) | tom.InlineTable(table) ->
            required_string(table, "kind", "source " <> name)
            |> result.map(fn(kind) { SourceSpec(name:, kind:, table:) })
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

/// Helpers for source modules reading their `[sources.<name>]` table.
/// Absent keys fall back to defaults; present-but-wrong-typed keys are
/// errors, so `port = "7444"` cannot silently mean 7333.
pub fn required_string(
  table: Dict(String, Toml),
  key: String,
  context: String,
) -> Result(String, String) {
  case tom.get_string(table, [key]) {
    Ok("") -> Error(context <> ": '" <> key <> "' is empty")
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Error(context <> ": missing '" <> key <> "'")
    Error(tom.WrongType(_, expected, got)) ->
      Error(wrong_type(context, key, expected, got))
  }
}

pub fn optional_string(
  table: Dict(String, Toml),
  key: String,
  default: String,
  context: String,
) -> Result(String, String) {
  case tom.get_string(table, [key]) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(tom.WrongType(_, expected, got)) ->
      Error(wrong_type(context, key, expected, got))
  }
}

pub fn optional_int(
  table: Dict(String, Toml),
  key: String,
  default: Int,
  context: String,
) -> Result(Int, String) {
  case tom.get_int(table, [key]) {
    Ok(value) -> Ok(value)
    Error(tom.NotFound(_)) -> Ok(default)
    Error(tom.WrongType(_, expected, got)) ->
      Error(wrong_type(context, key, expected, got))
  }
}

pub fn maybe_string(
  table: Dict(String, Toml),
  key: String,
  context: String,
) -> Result(Option(String), String) {
  case tom.get_string(table, [key]) {
    Ok(value) -> Ok(Some(value))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(_, expected, got)) ->
      Error(wrong_type(context, key, expected, got))
  }
}

pub fn string_list(
  table: Dict(String, Toml),
  key: String,
  context: String,
) -> Result(List(String), String) {
  case tom.get_array(table, [key]) {
    Error(_) -> Error(context <> ": missing '" <> key <> "' list")
    Ok(items) ->
      items
      |> list.try_map(fn(item) {
        case item {
          tom.String(value) -> Ok(value)
          _ -> Error(context <> ": '" <> key <> "' must be strings")
        }
      })
  }
}

/// Token from `token`, or the environment variable named by `token_env`.
pub fn token(
  table: Dict(String, Toml),
  context: String,
) -> Result(String, String) {
  case tom.get_string(table, ["token"]) {
    Ok(token) if token != "" -> Ok(token)
    Ok("") -> Error(context <> ": 'token' is empty")
    _ ->
      required_string(table, "token_env", context)
      |> result.map_error(fn(_) {
        context <> ": missing 'token' or 'token_env'"
      })
      |> result.try(fn(var) {
        case envoy.get(var) {
          Ok(value) if value != "" -> Ok(value)
          _ -> Error(context <> ": env " <> var <> " not set")
        }
      })
  }
}

/// Poll interval in milliseconds, default 30s, minimum 5s: a sub-second
/// interval is a config error, not an aggressive preference.
pub fn interval_ms(
  table: Dict(String, Toml),
  context: String,
) -> Result(Int, String) {
  use seconds <- result.try(optional_int(table, "interval_seconds", 30, context))
  case seconds >= 5 {
    True -> Ok(seconds * 1000)
    False -> Error(context <> ": 'interval_seconds' must be at least 5")
  }
}

/// Topic prefix, validated so a typo fails at boot rather than as an
/// endless stream of hub rejections.
pub fn topic_prefix(
  table: Dict(String, Toml),
  default: String,
  context: String,
) -> Result(String, String) {
  use prefix <- result.try(optional_string(
    table,
    "topic_prefix",
    default,
    context,
  ))
  case whisper.valid_topic(prefix) {
    True -> Ok(prefix)
    False -> Error(context <> ": 'topic_prefix' is not a valid topic prefix")
  }
}

fn wrong_type(
  context: String,
  key: String,
  expected: String,
  got: String,
) -> String {
  context
  <> ": '"
  <> key
  <> "' should be "
  <> string.lowercase(expected)
  <> ", got "
  <> string.lowercase(got)
}
