import envoy
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Settings {
  Settings(path: String, max_bytes: Int, max_files: Int)
}

pub const default_max_bytes = 10_485_760

pub const default_max_files = 5

pub type Level {
  Info
  Warning
}

@external(erlang, "reeds_log_ffi", "handler_config")
pub fn handler_config(path: String, max_bytes: Int, max_files: Int) -> Dynamic

@external(erlang, "reeds_log_ffi", "install")
fn install_handler(
  path: String,
  max_bytes: Int,
  max_files: Int,
) -> Result(Nil, String)

@external(erlang, "reeds_log_ffi", "raise_level")
pub fn raise_level() -> Nil

@external(erlang, "reeds_log_ffi", "log")
fn log(level: Level, message: String) -> Nil

/// `REEDS_LOG` unset means no file handler: logger keeps its stdout default,
/// which is what `gleam run` wants. Limits that do not parse as positive
/// integers fall back to the defaults.
pub fn settings(get: fn(String) -> Result(String, Nil)) -> Option(Settings) {
  case get("REEDS_LOG") {
    Error(_) | Ok("") -> None
    Ok(path) ->
      Some(Settings(
        path:,
        max_bytes: positive(get("REEDS_LOG_MAX_BYTES"), default_max_bytes),
        max_files: positive(get("REEDS_LOG_MAX_FILES"), default_max_files),
      ))
  }
}

fn positive(raw: Result(String, Nil), default: Int) -> Int {
  raw
  |> result.try(int.parse)
  |> result.try(fn(n) {
    case n > 0 {
      True -> Ok(n)
      False -> Error(Nil)
    }
  })
  |> result.unwrap(default)
}

/// Moves OTP logger, and with it every crash and supervisor report, into the
/// rotating file. Returns the error when the file cannot be opened; the
/// stdout handler stays in that case.
pub fn install() -> Result(Nil, String) {
  raise_level()
  case settings(envoy.get) {
    None -> Ok(Nil)
    Some(s) -> install_handler(s.path, s.max_bytes, s.max_files)
  }
}

pub fn info(message: String) -> Nil {
  log(Info, message)
}

pub fn warning(message: String) -> Nil {
  log(Warning, message)
}
