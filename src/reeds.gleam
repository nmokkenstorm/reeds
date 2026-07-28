import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import mist
import reeds/api
import reeds/hub
import reeds/source
import reeds/sources/bitbucket
import reeds/store

pub fn main() {
  let db_path = envoy.get("REEDS_DB") |> result.unwrap("reeds.db")
  let port =
    envoy.get("REEDS_PORT") |> result.try(int.parse) |> result.unwrap(7333)

  let assert Ok(conn) = store.open(db_path)
  io.println("reeds: " <> db_path <> " (sqlite " <> store.version(conn) <> ")")

  let assert Ok(started) = hub.start(conn)
  let hub_subject = started.data

  case bitbucket.from_env() {
    Some(src) -> {
      let assert Ok(_) = source.start(src, hub_subject)
      io.println("reeds: source bitbucket polling")
    }
    None ->
      io.println("reeds: source bitbucket disabled (BITBUCKET_* env not set)")
  }

  let assert Ok(_) =
    mist.new(api.handler(hub_subject))
    |> mist.bind("localhost")
    |> mist.port(port)
    |> mist.start
  io.println("reeds: listening on http://localhost:" <> int.to_string(port))

  process.sleep_forever()
}
