import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/result
import mist
import reeds/api
import reeds/config.{type SourceSpec}
import reeds/hub
import reeds/source.{type Source}
import reeds/sources/bitbucket
import reeds/sources/github
import reeds/store

pub fn main() {
  let config = case config.load(config_path()) {
    Ok(config) -> config
    Error(reason) -> panic as { "reeds: " <> reason }
  }
  let db_path = envoy.get("REEDS_DB") |> result.unwrap(config.db)
  let port =
    envoy.get("REEDS_PORT")
    |> result.try(int.parse)
    |> result.unwrap(config.port)

  let assert Ok(conn) = store.open(db_path)
  io.println("reeds: " <> db_path <> " (sqlite " <> store.version(conn) <> ")")

  let hub_name = process.new_name("reeds_hub")
  let hub_subject = process.named_subject(hub_name)
  let sources = list.map(config.sources, build_source)

  let web =
    mist.new(api.handler(hub_subject))
    |> mist.bind("localhost")
    |> mist.port(port)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(hub.supervised(conn, hub_name))
    |> list.fold(sources, _, fn(sup, src) {
      supervisor.add(sup, source.supervised(src, hub_subject))
    })
    |> supervisor.add(mist.supervised(web))
    |> supervisor.start
  io.println("reeds: listening on http://localhost:" <> int.to_string(port))

  process.sleep_forever()
}

fn config_path() -> String {
  case envoy.get("REEDS_CONFIG"), envoy.get("HOME") {
    Ok(path), _ -> path
    _, Ok(home) -> home <> "/.config/reeds/config.toml"
    _, _ -> panic as "reeds: neither REEDS_CONFIG nor HOME is set"
  }
}

/// A source that fails validation refuses the whole boot: a daemon quietly
/// running without a source you configured is worse than a loud crash.
fn build_source(spec: SourceSpec) -> Source {
  let built = case spec.kind {
    "bitbucket" -> bitbucket.from_spec(spec.name, spec.table)
    "github" -> github.from_spec(spec.name, spec.table)
    kind -> Error("source " <> spec.name <> ": unknown kind '" <> kind <> "'")
  }
  case built {
    Error(reason) -> panic as { "reeds: " <> reason }
    Ok(src) -> {
      io.println(
        "reeds: source " <> spec.name <> " (" <> spec.kind <> ") polling",
      )
      src
    }
  }
}
