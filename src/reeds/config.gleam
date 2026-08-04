import envoy
import gleam/dict.{type Dict}
import gleam/int
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
    peers: List(PeerSpec),
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

/// `pull` tails the peer's read API and ingests; `push` batches this
/// bridge's whispers to the peer's `/ingest`; `both` runs both halves. Every
/// mode's token also authenticates that peer's non-loopback requests here.
pub type PeerMode {
  Pull
  Push
  Both
}

pub type PeerSpec {
  PeerSpec(
    name: String,
    url: String,
    token: String,
    mode: PeerMode,
    interval_ms: Int,
    backoff_cap_ms: Int,
  )
}

/// A table plus the context every error it produces is labelled with, so a
/// source or peer module cannot mislabel its own failures or forget the
/// prefix.
pub opaque type Reader {
  Reader(table: Dict(String, Toml), context: String)
}

pub fn source_reader(name: String, table: Dict(String, Toml)) -> Reader {
  Reader(table:, context: "source " <> name)
}

pub fn peer_reader(name: String, table: Dict(String, Toml)) -> Reader {
  Reader(table:, context: "peer " <> name)
}

/// Load config from a TOML file, resolving its `import` list first. Only a
/// genuinely absent root file yields the defaults; unreadable or malformed
/// config is an error, so a permission mishap cannot silently boot a daemon
/// with zero sources. An import named but missing is an error for the same
/// reason: a boot without the tokens file would run every source without
/// credentials.
pub fn load(path: String) -> Result(Config, String) {
  case simplifile.read(path) {
    Ok(raw) -> {
      use toml <- result.try(parse_toml(raw, path))
      use merged <- result.try(resolve_imports(toml, dirname(path)))
      validate(merged)
    }
    Error(simplifile.Enoent) -> parse("")
    Error(error) -> Error(path <> ": " <> simplifile.describe_error(error))
  }
}

/// Parse a single TOML config document without following imports (the key is
/// still type-checked); exported for tests.
pub fn parse(raw: String) -> Result(Config, String) {
  use toml <- result.try(parse_toml(raw, "config"))
  use _ <- result.try(import_paths(toml))
  validate(dict.delete(toml, "import"))
}

fn parse_toml(
  raw: String,
  label: String,
) -> Result(Dict(String, Toml), String) {
  tom.parse(raw) |> result.replace_error(label <> " is not valid toml")
}

/// `import = ["tokens.toml"]`: each file is parsed and deep-merged into the
/// root document, so secrets can live in a separate file with tighter
/// permissions while `[sources.*]`/`[peers.*]` stay editable. Merging is
/// additive only: a leaf key defined twice is an error, never a shadowing
/// rule, and imports do not nest, so the config graph is one file plus its
/// listed fragments.
fn resolve_imports(
  toml: Dict(String, Toml),
  base_dir: String,
) -> Result(Dict(String, Toml), String) {
  use paths <- result.try(import_paths(toml))
  let root = dict.delete(toml, "import")
  let seen = index_leaves(root, at: [], label: "the root config", into: dict.new())
  list.try_fold(over: paths, from: #(root, seen), with: fn(state, path) {
    let #(acc, seen) = state
    let label = "config: import " <> path
    use resolved <- result.try(
      resolve_path(base_dir, path)
      |> result.map_error(fn(reason) { label <> ": " <> reason }),
    )
    use raw <- result.try(
      simplifile.read(resolved)
      |> result.map_error(fn(error) {
        label <> ": " <> simplifile.describe_error(error)
      }),
    )
    use imported <- result.try(parse_toml(raw, label))
    use _ <- result.try(case dict.has_key(imported, "import") {
      True -> Error(label <> ": imports do not nest")
      False -> Ok(Nil)
    })
    use _ <- result.try(secret_mode(resolved, imported, label))
    use merged <- result.try(merge(acc, imported, at: [], file: path, seen:))
    Ok(#(merged, index_leaves(imported, at: [], label: path, into: seen)))
  })
  |> result.map(fn(state) { state.0 })
}

/// Leaf key path -> the file that defined it, so a collision can name both
/// sides instead of only the file that lost.
fn index_leaves(
  table: Dict(String, Toml),
  at at: List(String),
  label label: String,
  into into: Dict(String, String),
) -> Dict(String, String) {
  dict.fold(table, into, fn(acc, key, value) {
    case value {
      tom.Table(inner) | tom.InlineTable(inner) ->
        index_leaves(inner, at: [key, ..at], label:, into: acc)
      _ -> dict.insert(acc, key_path([key, ..at]), label)
    }
  })
}

/// A file that defines a `token` anywhere must not be group- or
/// other-accessible, the same stance ssh takes on key files: the 0600 split
/// is the point of importing, so a world-readable tokens file is a
/// misconfiguration, not a preference.
fn secret_mode(
  resolved: String,
  imported: Dict(String, Toml),
  label: String,
) -> Result(Nil, String) {
  case contains_token(imported) {
    False -> Ok(Nil)
    True -> {
      use info <- result.try(
        simplifile.file_info(resolved)
        |> result.map_error(fn(error) {
          label <> ": " <> simplifile.describe_error(error)
        }),
      )
      case int.bitwise_and(info.mode, 0o77) {
        0 -> Ok(Nil)
        _ ->
          Error(
            label
            <> ": defines tokens but is group/other accessible; chmod 600 it",
          )
      }
    }
  }
}

fn contains_token(table: Dict(String, Toml)) -> Bool {
  dict.fold(table, False, fn(found, key, value) {
    found
    || case value {
      tom.Table(inner) | tom.InlineTable(inner) -> contains_token(inner)
      _ -> key == "token"
    }
  })
}

fn import_paths(toml: Dict(String, Toml)) -> Result(List(String), String) {
  case tom.get_array(toml, ["import"]) {
    Error(tom.NotFound(_)) -> Ok([])
    Error(tom.WrongType(..)) ->
      Error("config: 'import' should be an array of strings")
    Ok(items) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String("") -> Error("config: 'import' contains an empty path")
          tom.String(path) -> Ok(path)
          _ -> Error("config: 'import' should be an array of strings")
        }
      })
  }
}

fn merge(
  base: Dict(String, Toml),
  overlay: Dict(String, Toml),
  at at: List(String),
  file file: String,
  seen seen: Dict(String, String),
) -> Result(Dict(String, Toml), String) {
  dict.fold(overlay, Ok(base), fn(acc, key, value) {
    use acc <- result.try(acc)
    case dict.get(acc, key), value {
      Error(Nil), _ -> Ok(dict.insert(acc, key, value))
      Ok(tom.Table(existing)), tom.Table(incoming)
      | Ok(tom.Table(existing)), tom.InlineTable(incoming)
      | Ok(tom.InlineTable(existing)), tom.Table(incoming)
      | Ok(tom.InlineTable(existing)), tom.InlineTable(incoming)
      ->
        merge(existing, incoming, at: [key, ..at], file:, seen:)
        |> result.map(fn(merged) { dict.insert(acc, key, tom.Table(merged)) })
      Ok(_), _ -> {
        let path = key_path([key, ..at])
        let source = case dict.get(seen, path) {
          Ok(label) -> " in " <> label
          Error(Nil) -> ""
        }
        Error(
          "config: import "
          <> file
          <> ": '"
          <> path
          <> "' is already defined"
          <> source,
        )
      }
    }
  })
}

fn key_path(reversed: List(String)) -> String {
  reversed |> list.reverse |> string.join(".")
}

/// Absolute and `~/` paths stand alone; anything else is relative to the
/// importing file's directory, so the config directory can move as a unit.
fn resolve_path(base_dir: String, path: String) -> Result(String, String) {
  case path, envoy.get("HOME") {
    "/" <> _, _ -> Ok(path)
    "~/" <> rest, Ok(home) -> Ok(home <> "/" <> rest)
    "~/" <> _, Error(_) -> Error("cannot expand '~': HOME is not set")
    _, _ -> Ok(base_dir <> "/" <> path)
  }
}

fn dirname(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..parents] if parents != [] ->
      parents |> list.reverse |> string.join("/")
    _ -> "."
  }
}

fn validate(toml: Dict(String, Toml)) -> Result(Config, String) {
  let root = Reader(table: toml, context: "config")
  use port <- result.try(optional_int(root, "port", 7333))
  // Loopback by default: the log is unauthenticated, so a bind address is an
  // explicit decision, never something a default quietly makes for you.
  use bind <- result.try(optional_string(root, "bind", "localhost"))
  use db <- result.try(optional_string(root, "db", "reeds.db"))
  use bridge_name <- result.try(bridge_name(toml))
  use sources <- result.try(sources(toml))
  use peers <- result.try(peers(toml))
  Ok(Config(port:, bind:, db:, bridge_name:, sources:, peers:))
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

/// Peers this bridge syncs with. A cursor is a per-peer thing regardless of
/// mode, so every mode is parsed the same way; only the pull loop cares
/// whether `mode` includes pulling. Every mode's token also authenticates
/// that peer's non-loopback requests.
fn peers(toml: Dict(String, Toml)) -> Result(List(PeerSpec), String) {
  case tom.get_table(toml, ["peers"]) {
    Error(_) -> Ok([])
    Ok(tables) ->
      tables
      |> dict.to_list
      |> list.try_map(fn(entry) {
        let #(name, value) = entry
        use _ <- result.try(instance_name(name))
        case value {
          tom.Table(table) | tom.InlineTable(table) -> {
            let reader = peer_reader(name, table)
            use url <- result.try(required_string(reader, "url"))
            use token <- result.try(token(reader))
            use mode <- result.try(peer_mode(reader))
            use interval_ms <- result.try(interval_ms(reader))
            use backoff_cap_ms <- result.try(backoff_cap_ms(reader, interval_ms))
            Ok(PeerSpec(
              name:,
              url:,
              token:,
              mode:,
              interval_ms:,
              backoff_cap_ms:,
            ))
          }
          _ -> Error("peer " <> name <> ": not a table")
        }
      })
  }
}

fn peer_mode(reader: Reader) -> Result(PeerMode, String) {
  use raw <- result.try(optional_string(reader, "mode", "pull"))
  case raw {
    "pull" -> Ok(Pull)
    "push" -> Ok(Push)
    "both" -> Ok(Both)
    _ -> Error(problem(reader, "mode", "must be 'pull', 'push', or 'both'"))
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
/// Both at once is an error, not a precedence rule: with imports merging
/// files, "which credential wins" must never be answered silently.
pub fn token(reader: Reader) -> Result(String, String) {
  use direct <- result.try(lookup(reader, tom.get_string, "token"))
  use named <- result.try(lookup(reader, tom.get_string, "token_env"))
  case direct, named {
    Some(_), Some(_) ->
      Error(problem(reader, "token", "and 'token_env' are both set; pick one"))
    Some(""), None -> Error(problem(reader, "token", "is empty"))
    Some(value), None -> Ok(value)
    None, Some(var) ->
      case envoy.get(var) {
        Ok(value) if value != "" -> Ok(value)
        _ -> Error(reader.context <> ": env " <> var <> " not set")
      }
    None, None -> Error(reader.context <> ": missing 'token' or 'token_env'")
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
