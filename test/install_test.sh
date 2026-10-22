#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
pid=""
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

export REEDS_INSTALL="$work/app"
(cd "$root" && gleam export erlang-shipment >/dev/null 2>&1)
cp -R "$root/build/erlang-shipment" "$work/shipment"
export REEDS_SHIPMENT="$work/shipment"
failures=0
expect() {
  [ "$2" = "$3" ] && return 0
  echo "FAIL: $1 (want $3, got $2)"
  failures=$((failures + 1))
}
install() { "$root/bin/reeds-install" >/dev/null 2>&1; }
releases() { find "$work" -maxdepth 1 -name 'app.*[0-9]' | wc -l | tr -d ' '; }

mkdir "$REEDS_INSTALL.link" "$REEDS_INSTALL.19990101000000.tmp"
install
expect "install links app" "$([ -L "$REEDS_INSTALL" ] && echo yes || echo no)" yes
expect "leftover app.link directory is cleared" "$([ -e "$work/app.link" ] && echo yes || echo no)" no
first="$(/usr/bin/readlink -f "$REEDS_INSTALL")"

sed -e "s|@INSTALL@|$REEDS_INSTALL|g" -e "s|@PATH@|$PATH|g" -e "s|@HOME@|$HOME|g" -e "s|@DB@|$work/t.db|g" \
  "$root/launchd/dev.mokkenstorm.reeds.plist.template" >"$work/agent.plist"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
pid="$(REEDS_DB="$work/t.db" REEDS_PORT="$port" REEDS_BIND=127.0.0.1 REEDS_CONFIG="$work/none.toml" REEDS_LOG="$work/reeds.log" \
  python3 -I -c '
import plistlib, subprocess, sys
args = plistlib.load(open(sys.argv[1], "rb"))["ProgramArguments"]
print(subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid)
' "$work/agent.plist")"
until curl -sf -o /dev/null "http://127.0.0.1:$port/health" || [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health")" != 000 ]; do sleep 0.2; done

install
second="$(/usr/bin/readlink -f "$REEDS_INSTALL")"
expect "swap moved the link" "$([ "$first" != "$second" ] && echo yes || echo no)" yes
cmd="$(ps -o command= -p "$pid")"
expect "running daemon code path is its starting release" "$(case "$cmd" in *"$first"/*) echo yes ;; *) echo no ;; esac)" yes
expect "running daemon never sees the new release" "$(case "$cmd" in *"$second"*) echo yes ;; *) echo no ;; esac)" no

install
expect "running release survives two more installs" "$([ -d "$first" ] && echo yes || echo no)" yes
expect "running release plus the newest two are kept" "$(releases)" 3
expect "leftover .tmp not pruned or promoted" "$([ -d "$REEDS_INSTALL.19990101000000.tmp" ] && echo yes || echo no)" yes

kill "$pid"; wait "$pid" 2>/dev/null || true; pid=""
install
expect "release is pruned once nothing runs from it" "$([ -d "$first" ] && echo yes || echo no)" no
expect "two releases kept once nothing runs" "$(releases)" 2

mkdir "$work/bin"
printf '#!/bin/sh\necho 20991231235959\n' >"$work/bin/date"
chmod +x "$work/bin/date"
PATH="$work/bin:$PATH" install
PATH="$work/bin:$PATH" install
expect "same-second installs land as two releases" "$(find "$work" -maxdepth 1 -name 'app.20991231235959*' | wc -l | tr -d ' ')" 2
expect "same-second installs never nest" "$(find "$work"/app.20991231235959* -mindepth 1 -maxdepth 1 -name 'app.*' | wc -l | tr -d ' ')" 0

[ "$failures" = 0 ] && echo "install: all assertions passed"
exit "$failures"
