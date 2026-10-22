#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export REEDS_WATCHDOG_URL="http://127.0.0.1:$port/health"
export REEDS_WATCHDOG_STATE_DIR="$work/state"
export REEDS_WATCHDOG_THRESHOLD=3
export REEDS_WATCHDOG_COOLDOWN=600
export REEDS_WATCHDOG_TIMEOUT=1
export REEDS_WATCHDOG_RESTART_CMD="$work/restart"
export REEDS_WATCHDOG_PUBLISH_CMD="$work/publish"

printf '#!/bin/sh\necho x >> "%s/restarts"\n' "$work" >"$work/restart"
printf '#!/bin/sh\necho "$@" >> "%s/whispers"\n' "$work" >"$work/publish"
chmod +x "$work/restart" "$work/publish"

failures=0
count() { [ -f "$work/$1" ] && wc -l <"$work/$1" | tr -d ' ' || echo 0; }
expect() {
  [ "$2" = "$3" ] && return 0
  echo "FAIL: $1 (want $3, got $2)"
  failures=$((failures + 1))
}
probe() { "$root/bin/reeds-watchdog" >/dev/null; }

probe; probe
expect "no restart below threshold" "$(count restarts)" 0
probe
expect "restart on third miss" "$(count restarts)" 1
probe; probe
expect "no second restart inside cooldown" "$(count restarts)" 1

sed -i.bak 's/^last_restart=.*/last_restart=1/' "$work/state/watchdog.state"
probe
expect "restart again once the cooldown passed" "$(count restarts)" 2

mkdir "$work/www" && printf ok >"$work/www/health"
(cd "$work/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
trap 'kill $server 2>/dev/null || true; rm -rf "$work"' EXIT
until curl -sf -o /dev/null "$REEDS_WATCHDOG_URL"; do sleep 0.1; done

probe
expect "one whisper on recovery" "$(count whispers)" 1
grep -q '^reeds.meta ' "$work/whispers" || expect "whisper topic" "missing" "reeds.meta"
probe
expect "no repeat whisper" "$(count whispers)" 1
expect "counter reset on success" "$(sed -n 's/^fails=//p' "$work/state/watchdog.state")" 0

kill "$server"; wait "$server" 2>/dev/null || true
probe; probe
expect "counter restarts from zero after a success" "$(count restarts)" 2

[ "$failures" = 0 ] && echo "watchdog: all assertions passed"
exit "$failures"
