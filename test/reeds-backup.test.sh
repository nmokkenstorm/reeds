#!/usr/bin/env bash
# shellcheck disable=SC2329
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="$ROOT/bin/reeds-backup"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}

mkdb() {
  sqlite3 "$1" 'PRAGMA journal_mode=WAL; CREATE TABLE w(id INTEGER PRIMARY KEY, body TEXT);' >/dev/null
  sqlite3 "$1" "INSERT INTO w(body) VALUES ('a'),('b'),('c');"
}

: > "$work/empty.env"
printf '/Volumes/Fake on /dev/disk9s1 (apfs, local)\n' > "$work/mounts"
: > "$work/mounts-none"

# Clean env per run; args are VAR=value overrides on top of the defaults.
bk() {
  env -i PATH="$PATH" HOME="$work/home" REEDS_BIN=/usr/bin/true \
    REEDS_CONFIG="$work/none.toml" REEDS_BACKUP_CONFIG="$work/empty.env" \
    REEDS_BACKUP_MOUNTS_FILE="$work/mounts" "$@" "$BACKUP"
}
fails_with() { ! bk "$@" 2>"$work/err"; }
newest() { ls "$work"/dest/"$1"-*.db.gz; }
restorable() {
  gunzip -c "$(newest reeds)" > "$work/restored.db"
  [ "$(sqlite3 "$work/restored.db" 'PRAGMA integrity_check')" = "ok" ] &&
    [ "$(sqlite3 "$work/restored.db" 'SELECT count(*) FROM w')" = "3" ]
}
reset() { rm -rf "$work/dest"; }

mkdb "$work/live.db"
base=(REEDS_DB="$work/live.db" REEDS_BACKUP_DEST="$work/dest")

check "no-mount mode writes" bk "${base[@]}"
check "backup is restorable and intact" restorable

reset
mounted=(REEDS_BACKUP_DEST=/Volumes/Fake/backups REEDS_BACKUP_REQUIRE_MOUNT=/Volumes/Fake)
check "unmounted volume exits 0" bk REEDS_DB="$work/live.db" "${mounted[@]}" REEDS_BACKUP_MOUNTS_FILE="$work/mounts-none"
check "unmounted volume writes nothing" test ! -e "$work/dest"

printf 'REEDS_DB=%s\nREEDS_BACKUP_DEST=%s\nREEDS_BACKUP_PREFIX=fromfile\n' "$work/live.db" "$work/dest" > "$work/a.env"
check "config file is read" bk REEDS_BACKUP_CONFIG="$work/a.env"
check "file prefix applied" test -e "$work/dest/fromfile-$(date +%Y-%m-%d).db.gz"
reset
check "env overrides file" bk REEDS_BACKUP_CONFIG="$work/a.env" REEDS_BACKUP_PREFIX=fromenv
check "env prefix wins" test -e "$work/dest/fromenv-$(date +%Y-%m-%d).db.gz"
check "env prefix beats file (no file prefix)" test ! -e "$work/dest/fromfile-$(date +%Y-%m-%d).db.gz"

printf 'REEDS_BACKUP_DEST=%s\nREEDS_BOGUS=1\n' "$work/dest" > "$work/bad1.env"
check "unknown key rejected" fails_with REEDS_DB="$work/live.db" REEDS_BACKUP_CONFIG="$work/bad1.env"
check "unknown key named in error" grep -q REEDS_BOGUS "$work/err"
printf 'not a pair\n' > "$work/bad2.env"
check "malformed line rejected" fails_with REEDS_BACKUP_CONFIG="$work/bad2.env"
check "missing explicit config rejected" fails_with "${base[@]}" REEDS_BACKUP_CONFIG="$work/absent.env"
check "missing dest rejected" fails_with REEDS_DB="$work/live.db"
check "relative dest rejected" fails_with REEDS_DB="$work/live.db" REEDS_BACKUP_DEST=rel
check "dest outside mount rejected" fails_with REEDS_DB="$work/live.db" REEDS_BACKUP_DEST="$work/dest" REEDS_BACKUP_REQUIRE_MOUNT=/Volumes/Fake
for bad in 0 -3 abc 1.5 ""; do
  check "keep_days '$bad' rejected" fails_with "${base[@]}" REEDS_BACKUP_KEEP_DAYS="$bad"
done
reset
check "bad prefix rejected" fails_with "${base[@]}" REEDS_BACKUP_PREFIX='Bad_Prefix'
check "missing db fails" fails_with REEDS_DB="$work/none.db" REEDS_BACKUP_DEST="$work/dest"
check "rejection writes nothing" test ! -e "$work/dest"

mkdir -p "$work/dest"
touch -t 202001010000 "$work/dest/reeds-2020-01-01.db.gz" "$work/dest/other-2020-01-01.db.gz" "$work/dest/notes-old.txt"
touch "$work/dest/reeds-2099-01-01.db.gz"
bk "${base[@]}"
check "prune old matching" test ! -e "$work/dest/reeds-2020-01-01.db.gz"
check "prune keeps other prefix" test -e "$work/dest/other-2020-01-01.db.gz"
check "prune keeps non-matching" test -e "$work/dest/notes-old.txt"
check "prune keeps recent" test -e "$work/dest/reeds-2099-01-01.db.gz"
bk "${base[@]}" REEDS_BACKUP_PREFIX=other
check "prefix drives retention" test ! -e "$work/dest/other-2020-01-01.db.gz"

reset
mkdir -p "$work/home/.config"
dbdir="$work/repo-db"; mkdir -p "$dbdir"; mkdb "$dbdir/from-toml.db"
printf '# c\ndb = "%s"\nport = 1\n[sources.x]\ndb = "/wrong.db"\n' "$dbdir/from-toml.db" > "$work/cfg.toml"
check "db read from config.toml" bk REEDS_BACKUP_DEST="$work/dest" REEDS_CONFIG="$work/cfg.toml"
check "config.toml db used" test -e "$work/dest/reeds-$(date +%Y-%m-%d).db.gz"
printf '[sources.x]\ndb = "%s"\n' "$work/live.db" > "$work/cfg2.toml"
check "nested db key ignored" fails_with REEDS_BACKUP_DEST="$work/dest" REEDS_CONFIG="$work/cfg2.toml"

reset
check "dest dir is 700" bk "${base[@]}"
check "dest dir mode" test "$(stat -f %Lp "$work/dest")" = 700
check "archive mode" test "$(stat -f %Lp "$(newest reeds)")" = 600

reset
mkdir -p "$work/real"; ln -sfn "$work/real" "$work/link"
touch -t 202001010000 "$work/real/reeds-2020-01-01.db.gz"
check "symlinked dest backs up" bk REEDS_DB="$work/live.db" REEDS_BACKUP_DEST="$work/link"
check "symlinked dest still prunes" test ! -e "$work/real/reeds-2020-01-01.db.gz"

# whisper hygiene: capture what would be published
cat > "$work/fakereeds" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$3" > "$FAKE_OUT"
FAKE
chmod +x "$work/fakereeds"
printf 'REEDS_BACKUP_DEST=%s\nSECRET\tTOKEN=hunter2\n' "$work/dest" > "$work/tab.env"
check "control-char line rejected" fails_with REEDS_DB="$work/live.db" REEDS_BACKUP_CONFIG="$work/tab.env" REEDS_BIN="$work/fakereeds" FAKE_OUT="$work/whisper"
check "whisper is valid json" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$work/whisper"
check "whisper names the line" grep -q 'line 2' "$work/whisper"
check "whisper omits raw content" bash -c "! grep -q hunter2 '$work/whisper'"

check "dotdot dest rejected" fails_with REEDS_DB="$work/live.db" REEDS_BACKUP_DEST="$work/vol/../dest" REEDS_BACKUP_REQUIRE_MOUNT="$work/vol"

reset
mkdir -p "$work/vol" "$work/outside"; ln -sfn "$work/outside" "$work/vol/escape"
printf '/dev/disk9s1 on %s (apfs, local)\n' "$work/vol" > "$work/mounts-vol"
volenv=(REEDS_DB="$work/live.db" REEDS_BACKUP_MOUNTS_FILE="$work/mounts-vol" REEDS_BACKUP_REQUIRE_MOUNT="$work/vol")
check "mounted dest backs up" bk "${volenv[@]}" REEDS_BACKUP_DEST="$work/vol/b"
check "mounted dest has archive" test -e "$work/vol/b/reeds-$(date +%Y-%m-%d).db.gz"
check "symlink escaping the mount rejected" fails_with "${volenv[@]}" REEDS_BACKUP_DEST="$work/vol/escape/b"
check "escape wrote nothing" bash -c "! ls '$work'/outside/b/* 2>/dev/null"

uuid=11111111-2222-3333-4444-555555555555
cat > "$work/fakediskutil" <<'FAKE'
#!/usr/bin/env bash
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>VolumeUUID</key><string>%s</string></dict></plist>' "$FAKE_UUID"
FAKE
chmod +x "$work/fakediskutil"
uuidenv=("${volenv[@]}" REEDS_BACKUP_DEST="$work/vol/u" REEDS_BACKUP_DISKUTIL="$work/fakediskutil")
check "matching uuid backs up" bk "${uuidenv[@]}" REEDS_BACKUP_VOLUME_UUID="$uuid" FAKE_UUID=11111111-2222-3333-4444-555555555555
check "matching uuid has archive" test -e "$work/vol/u/reeds-$(date +%Y-%m-%d).db.gz"
rm -rf "$work/vol/u"
check "uuid mismatch refused" fails_with "${uuidenv[@]}" REEDS_BACKUP_VOLUME_UUID="$uuid" FAKE_UUID=99999999-2222-3333-4444-555555555555
check "uuid mismatch writes nothing" test ! -e "$work/vol/u"
check "malformed uuid rejected" fails_with "${uuidenv[@]}" REEDS_BACKUP_VOLUME_UUID=nope
check "uuid without mount rejected" fails_with "${base[@]}" REEDS_BACKUP_VOLUME_UUID="$uuid"

cat > "$work/okreeds" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$FAKE_OUT"
FAKE
chmod +x "$work/okreeds"
check "no db anywhere is a clear error" fails_with REEDS_BACKUP_DEST="$work/dest"
check "error says how to fix it" grep -q 'set REEDS_DB' "$work/err"

reset
check "success whispers" bk "${base[@]}" REEDS_BIN="$work/okreeds" FAKE_OUT="$work/ok"
check "success topic" test "$(sed -n 1p "$work/ok")" = reeds.meta.backup
check "success kind" test "$(sed -n 3p "$work/ok")" = status
check "success payload has date, size, dest" python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read().splitlines()[1]); assert d["event"]=="backup.ok" and d["bytes"]>0 and d["dest"].endswith(sys.argv[2]) and d["date"]==sys.argv[3]' "$work/ok" "/dest/reeds-$(date +%Y-%m-%d).db.gz" "$(date +%Y-%m-%d)"
check "failed publish does not fail the backup" bk "${base[@]}" REEDS_BIN=/usr/bin/false
check "failure uses the same topic" fails_with REEDS_BACKUP_DEST="$work/dest" REEDS_BIN="$work/okreeds" FAKE_OUT="$work/fail"
check "failure topic" test "$(sed -n 1p "$work/fail")" = reeds.meta.backup
check "failure kind" test "$(sed -n 3p "$work/fail")" = needs-user

reset
mkdir -p "$work/rel/real" "$work/rel/link"
cp "$BACKUP" "$work/rel/real/reeds-backup"
cp "$work/okreeds" "$work/rel/real/reeds-cli"
ln -s ../real/reeds-backup "$work/rel/link/reeds-backup"
check "symlinked script finds reeds-cli beside its target" env -i PATH="$PATH" HOME="$work/home" FAKE_OUT="$work/viasym" \
  REEDS_CONFIG="$work/none.toml" REEDS_BACKUP_CONFIG="$work/empty.env" REEDS_DB="$work/live.db" REEDS_BACKUP_DEST="$work/dest" "$work/rel/link/reeds-backup"
check "cli lookup used the real directory" test "$(sed -n 1p "$work/viasym")" = reeds.meta.backup

exit "$fails"
