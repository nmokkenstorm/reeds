# Running the daemon

## macOS (launchd)

The agent runs an installed `erlang-shipment`, so a restart never compiles and
the daemon does not care which branch is checked out. `bin/reeds-install`
exports the shipment and swaps it in; the checkout and the Gleam toolchain are
build-time only.

```sh
bin/reeds-install                        # ~/.local/share/reeds/app, or REEDS_INSTALL=<path>
```

Each run builds into a sibling `app.<timestamp>` directory and repoints the
`app` symlink with one rename, keeping the previous two releases. A running
daemon keeps using the release it started from until it is restarted.

launchd expands neither `~` nor environment variables, so the templates carry
placeholders. `@DB@` is the whisper log and is always set explicitly: the
agent exports `REEDS_DB`, which takes precedence over `db` in `config.toml`
(`src/reeds.gleam` reads the environment first), so the plist is the single
source of truth for it. `REEDS_CONFIG` is pinned the same way and the working
directory is `$HOME`; a relative `db` would otherwise resolve against it.

```sh
INSTALL=$HOME/.local/share/reeds/app
DB=$HOME/.local/share/reeds/reeds.db     # or wherever the existing log lives
sed -e "s|@INSTALL@|$INSTALL|g" \
    -e "s|@PATH@|$(dirname "$(command -v erl)"):/usr/bin:/bin|g" \
    -e "s|@HOME@|$HOME|g" \
    -e "s|@DB@|$DB|g" \
  launchd/dev.mokkenstorm.reeds.plist.template \
  > ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist

plutil -lint ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist
launchctl kickstart -k gui/$(id -u)/dev.mokkenstorm.reeds   # restart
```

`erl` has to be on the agent's `PATH` (`entrypoint.sh` calls it), hence the
`dirname` of `command -v erl`. To reuse an existing database, point `DB` at it
(stop the daemon before moving one, and move `-wal` and `-shm` along).

### Logs

The daemon logs through OTP `logger`: app lines, crash reports and supervisor
reports all land in `REEDS_LOG` (`~/Library/Logs/reeds.log` in the plist) via a
`logger_std_h` file handler that rotates itself, so there is no pipe, no
wrapper process and no root step. `src/reeds/logs.gleam` installs the handler
when `main` starts; with `REEDS_LOG` unset the stdout default stays, which is
what `gleam run` wants.

| Variable              | Default             |
| --------------------- | ------------------- |
| `REEDS_LOG`           | unset (stdout)      |
| `REEDS_LOG_MAX_BYTES` | `10485760` (10 MiB) |
| `REEDS_LOG_MAX_FILES` | `5`                 |

Rotated generations are `reeds.log.0.gz` (newest) through `reeds.log.4.gz`.
Logging is asynchronous and drops lines past a 2000 message queue rather than
blocking the daemon. If the log file cannot be opened the daemon says so and
stays on stdout.

launchd's `StandardOutPath` and `StandardErrorPath` point at
`~/Library/Logs/reeds.stdout.log`, which stays near-empty: mist prints one
`Listening on ...` line per boot, and anything the VM writes before `main`
runs or after the handler is gone (boot failures, `erl` errors) lands there.

### Watchdog

A wedged daemon keeps its port open, so `KeepAlive` never fires. The watchdog
agent runs `reeds-watchdog` every 60 seconds: it probes `/health` with a 3 second
timeout and counts consecutive failures in `~/.local/state/reeds/watchdog.state`.
At 3 it runs `launchctl kickstart -k` on the daemon, then refuses to restart
again for 10 minutes so a slow boot is not killed. Each restart is logged to
`~/Library/Logs/reeds-watchdog.log` (capped at 1 MiB, one `.1` generation kept), and once `/health` answers again it
publishes one whisper on `reeds.meta`.

```sh
sed -e "s|@INSTALL@|$INSTALL|g" -e "s|@HOME@|$HOME|g" \
  launchd/dev.mokkenstorm.reeds.watchdog.plist.template \
  > ~/Library/LaunchAgents/dev.mokkenstorm.reeds.watchdog.plist

plutil -lint ~/Library/LaunchAgents/dev.mokkenstorm.reeds.watchdog.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mokkenstorm.reeds.watchdog.plist
```

Every knob is an environment variable, set in the plist when you need it:

| Variable                     | Default                                                  |
| ---------------------------- | -------------------------------------------------------- |
| `REEDS_WATCHDOG_URL`         | `http://localhost:7333/health`                           |
| `REEDS_WATCHDOG_THRESHOLD`   | `3`                                                      |
| `REEDS_WATCHDOG_COOLDOWN`    | `600` (seconds)                                          |
| `REEDS_WATCHDOG_TIMEOUT`     | `3` (seconds)                                            |
| `REEDS_WATCHDOG_STATE_DIR`   | `~/.local/state/reeds`                                   |
| `REEDS_WATCHDOG_RESTART_CMD` | `launchctl kickstart -k gui/<uid>/dev.mokkenstorm.reeds` |
| `REEDS_WATCHDOG_PUBLISH_CMD` | `reeds-cli pub` (called with topic, body, kind)          |
| `REEDS_WATCHDOG_LOG`         | unset (stdout); the plist sets the log path              |
| `REEDS_WATCHDOG_LOG_MAX`     | `1048576` (bytes)                                        |

`test/watchdog_test.sh` runs it against a closed port with a stubbed restart:
one restart after three misses, none inside the cooldown, a counter that resets
on success, and one whisper on recovery.

## Linux (systemd)

A user unit, so it needs no root and `%h` resolves to your home. It runs an
`erlang-shipment`, which means the checkout and the Gleam toolchain are
build-time only:

```sh
gleam export erlang-shipment
mkdir -p ~/.local/share/reeds ~/.config/systemd/user
cp -r build/erlang-shipment ~/.local/share/reeds/app

sed "s|@INSTALL@|$HOME/.local/share/reeds/app|g" \
  systemd/reeds.service.template > ~/.config/systemd/user/reeds.service

systemctl --user daemon-reload
systemctl --user enable --now reeds
journalctl --user -u reeds -f          # logs
loginctl enable-linger "$USER"         # keep running when logged out
```

## Docker

```sh
docker build -t reeds .
docker run -d --name reeds \
  -p 127.0.0.1:7333:7333 \
  -v reeds-data:/data \
  -v ~/.config/reeds/config.toml:/etc/reeds/config.toml:ro \
  reeds
```

The image sets `REEDS_BIND=0.0.0.0`, because loopback inside a container binds
the container's own interface and a published port would never reach it.
Publishing as `127.0.0.1:7333:7333` rather than `7333:7333` puts the loopback
restriction back where it belongs, on the host side. The whisper log lives on
the `reeds-data` volume; without it, every container restart starts an empty
network.

Multi-stage on Alpine: Gleam builds the shipment, `erlang:29-alpine` runs it as
a non-root user. Both stages are musl on purpose, since `esqlite` is a NIF and a
glibc runtime would fail to load what the build stage compiled.
