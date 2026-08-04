import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/result
import mist
import reeds/api
import reeds/config.{type PeerSpec, type SourceSpec, Push}
import reeds/health
import reeds/hub
import reeds/peer
import reeds/source.{type Source}
import reeds/sources/bitbucket
import reeds/sources/github
import reeds/sources/gitlab
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
  let bind = envoy.get("REEDS_BIND") |> result.unwrap(config.bind)

  let assert Ok(conn) = store.open(db_path, origin: config.bridge_name)
  io.println(
    "reeds: "
    <> db_path
    <> " (sqlite "
    <> store.version(conn)
    <> ", origin "
    <> config.bridge_name
    <> ")",
  )

  let hub_name = process.new_name("reeds_hub")
  let hub_subject = process.named_subject(hub_name)
  let #(active, disabled) =
    list.partition(config.sources, fn(spec) { spec.enabled })
  list.each(disabled, announce_disabled)
  let sources = list.map(active, build_source)
  // A `push`-only peer has no pull loop to run yet; `both` still gets one,
  // since pulling is the half of it that exists.
  let pulling_peers = list.filter(config.peers, fn(p) { p.mode != Push })
  list.each(pulling_peers, announce_peer)

  let peer_tokens = list.map(config.peers, fn(peer) { peer.token })
  let web =
    mist.new(api.handler(hub_subject, peer_tokens))
    |> mist.bind(bind)
    |> mist.port(port)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(hub.supervised(conn, config.bridge_name, hub_name))
    |> list.fold(sources, _, fn(sup, src) {
      supervisor.add(sup, source.supervised(src, hub_subject))
    })
    |> list.fold(pulling_peers, _, fn(sup, p) {
      supervisor.add(sup, peer.supervised(p, hub_subject))
    })
    |> supervisor.add(mist.supervised(web))
    |> supervisor.start
  // The roster is what `/health` reports against, so a configured source
  // shows up as disabled or unknown instead of quietly missing.
  process.send(
    hub_subject,
    hub.SetRoster(list.append(
      list.map(config.sources, fn(spec) {
        health.Registration(
          name: spec.name,
          kind: spec.kind,
          enabled: spec.enabled,
        )
      }),
      list.map(pulling_peers, fn(p) {
        health.Registration(
          name: "peer-" <> p.name,
          kind: "peer",
          enabled: True,
        )
      }),
    )),
  )
  io.println(
    "reeds: listening on http://" <> bind <> ":" <> int.to_string(port),
  )

  process.sleep_forever()
}

fn config_path() -> String {
  case envoy.get("REEDS_CONFIG"), envoy.get("HOME") {
    Ok(path), _ -> path
    _, Ok(home) -> home <> "/.config/reeds/config.toml"
    _, _ -> panic as "reeds: neither REEDS_CONFIG nor HOME is set"
  }
}

/// `enabled = false` skips validation as well as polling, so a source can be
/// parked without its now-stale credentials refusing the boot. Announced on
/// stdout because a silently absent source is the failure mode reeds avoids.
fn announce_disabled(spec: SourceSpec) -> Nil {
  io.println("reeds: source " <> spec.name <> " (" <> spec.kind <> ") disabled")
}

fn announce_peer(peer: PeerSpec) -> Nil {
  io.println("reeds: peer " <> peer.name <> " (" <> peer.url <> ") pulling")
}

/// A source that fails validation refuses the whole boot: a daemon quietly
/// running without a source you configured is worse than a loud crash.
fn build_source(spec: SourceSpec) -> Source {
  let built = case spec.kind {
    "bitbucket" -> bitbucket.from_spec(spec.name, spec.table)
    "github" -> github.from_spec(spec.name, spec.table)
    "gitlab" -> gitlab.from_spec(spec.name, spec.table)
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
