# Running the daemon

## macOS (launchd)

`launchd/dev.mokkenstorm.reeds.plist.template` keeps the daemon running
(`KeepAlive`, `RunAtLoad`, logs to `~/Library/Logs/reeds.log`). launchd expands
neither `~` nor environment variables in paths, so the template carries
placeholders and you fill them in from the repo root:

```sh
sed -e "s|@GLEAM@|$(command -v gleam)|g" \
    -e "s|@REPO@|$PWD|g" \
    -e "s|@PATH@|$(dirname "$(command -v gleam)"):/usr/bin:/bin|g" \
    -e "s|@HOME@|$HOME|g" \
  launchd/dev.mokkenstorm.reeds.plist.template \
  > ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist

plutil -lint ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist
launchctl kickstart -k gui/$(id -u)/dev.mokkenstorm.reeds   # restart
```

The agent runs `gleam run` from the checkout, so the repo has to stay where it
is and the Gleam toolchain has to remain installed. Re-run the `sed` after
moving either.

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
