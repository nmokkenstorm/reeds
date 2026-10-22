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

### Log rotation

The agent starts the daemon through `reeds-run`, which appends every output line
with a fresh open instead of holding a descriptor. newsyslog renames the log, so
a daemon holding the old descriptor would keep writing into the rotated (then
compressed and unlinked) file and the live log would go silent.

`launchd/reeds.newsyslog.conf.template` rotates `reeds.log` at 10 MB and keeps
five bzip2-compressed generations; the watchdog log rotates at 1 MB and keeps
three. Installing needs root:

```sh
sed -e "s|@HOME@|$HOME|g" -e "s|@USER@|$USER|g" \
  launchd/reeds.newsyslog.conf.template \
  | sudo tee /etc/newsyslog.d/reeds.conf >/dev/null
sudo newsyslog -nv -f /etc/newsyslog.d/reeds.conf   # dry run
```

macOS runs newsyslog hourly, so rotation lands within the hour after the size
is crossed.

### Watchdog

A wedged daemon keeps its port open, so `KeepAlive` never fires. The watchdog
agent runs `reeds-watchdog` every 60 seconds: it probes `/health` with a 3 second
timeout and counts consecutive failures in `~/.local/state/reeds/watchdog.state`.
At 3 it runs `launchctl kickstart -k` on the daemon, then refuses to restart
again for 10 minutes so a slow boot is not killed. Each restart is logged to
`~/Library/Logs/reeds-watchdog.log`, and once `/health` answers again it
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
