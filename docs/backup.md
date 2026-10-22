# Backup

`bin/reeds-backup` takes a consistent online snapshot of the database and
ships it to an external volume. A plain file copy of a WAL database can be
torn; `sqlite3 .backup` cannot, and it is safe while the daemon is running.

Each run:

1. Exits 0 silently if `REEDS_BACKUP_REQUIRE_MOUNT` is set and not mounted (checked against the mount
   table, so nothing is ever written into an unmounted `/Volumes` path).
2. Snapshots the database into a temp directory with `.backup`.
3. Runs `PRAGMA integrity_check` on the snapshot; anything but `ok` fails.
4. Gzips it and `rsync`s it to `$DEST/reeds-<YYYY-MM-DD>.db.gz`.
5. Deletes `<prefix>-????-??-??.db.gz` files in `$DEST` older than `REEDS_BACKUP_KEEP_DAYS` (30) days.
   Nothing else in the directory is touched.

On success it publishes one `status` whisper on `reeds.meta.backup` (event
`backup.ok`, with date, byte size and destination file), best effort. On a real
failure it publishes `needs-user` on the same topic and exits non-zero. Sharing
the topic means the next good run clears the alert, and `/dashboard` always
shows the last good backup with its age.

An unmounted volume stays silent by design, so staleness is the signal: if the
drive is away for days, the `reeds.meta.backup` entry just keeps ageing. Treat
an age past a day or two as the alert.

## Configuration

Settings come from a plain `KEY=VALUE` file, `~/.config/reeds/backup.env` by
default (`REEDS_BACKUP_CONFIG` overrides the path). It is parsed, never
sourced: unknown keys and malformed lines fail the run. Environment variables
override the file. A copy to start from is `backup.env.example`.

| Key                          | Default                                      | Meaning                                                                 |
| ---------------------------- | -------------------------------------------- | ----------------------------------------------------------------------- |
| `REEDS_BACKUP_DEST`          | none, required                               | Absolute directory that receives the archives                           |
| `REEDS_BACKUP_REQUIRE_MOUNT` | empty                                        | Mount point that must be mounted, else exit 0; empty disables the check |
| `REEDS_BACKUP_KEEP_DAYS`     | `30`                                         | Positive integer; older archives are pruned                             |
| `REEDS_BACKUP_VOLUME_UUID`   | empty                                        | Optional VolumeUUID the mount must have; mismatch fails and whispers    |
| `REEDS_BACKUP_PREFIX`        | `reeds`                                      | Filename prefix, `[a-z0-9-]`; the prune pattern follows it              |
| `REEDS_DB`                   | top-level `db` of config.toml, else an error | Database to snapshot                                                    |

The config.toml consulted is `REEDS_CONFIG` or `~/.config/reeds/config.toml`,
the same lookup the daemon uses. Only a top-level `db = "..."` line before
the first table is read; a relative path resolves against `$HOME`, as for the daemon. With neither
`REEDS_DB` nor a `db` line the run fails with a clear error.

`REEDS_BACKUP_VOLUME_UUID` needs `REEDS_BACKUP_REQUIRE_MOUNT`. It guards
against a different disk mounted under the same name. Find it with
`diskutil info -plist /Volumes/<name>` and copy `VolumeUUID`; tests override
the tool with `REEDS_BACKUP_DISKUTIL`.

`REEDS_BACKUP_DEST` and the mount point may not contain `..` segments, and the
destination must resolve (symlinks followed) to somewhere under the mount
point; this is checked before anything is created.

Everything is validated before the snapshot starts. When a mount point is
set, `REEDS_BACKUP_DEST` must live under it. Test seam:
`REEDS_BACKUP_MOUNTS_FILE` points at fake `mount` output.

## Permissions and encryption

The script runs with `umask 077`: the destination directory is created `700`
and archives are set `600` before `rsync -a` copies them. That does not protect
you on an external drive, because macOS ignores ownership on external volumes
by default, so any local user or process that can read the volume can read
the archives. They contain every whisper and claim in plaintext. Use an
encrypted APFS volume (Finder: Erase with APFS (Encrypted), or
`diskutil apfs encryptVolume`) for the destination; treat an unencrypted one
as a leak waiting for a lost drive.

Whispers on `reeds.meta.backup` are forwarded to peers, so they carry only
the stage and a short reason, never config values or raw config lines. The
success whisper does name the destination file.

## Install

The script ships inside the release, next to `reeds-watchdog`, so the job
never depends on a checkout. Install (or reinstall) the release, write the
config, render the template, lint it, load it. The plist resolves the `app`
link with `readlink -f` at each launch, like the daemon plist, so a new
release is picked up without touching the job. The schedule is
`@HOUR@:@MINUTE@`:

```sh
bin/reeds-install
mkdir -p ~/.config/reeds
cp backup.env.example ~/.config/reeds/backup.env   # then edit
sed -e "s|@INSTALL@|$HOME/.local/share/reeds/app|g" \
    -e "s|@PATH@|/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin|g" \
    -e "s|@HOME@|$HOME|g" \
    -e "s|@HOUR@|3|g" -e "s|@MINUTE@|30|g" \
  launchd/dev.mokkenstorm.reeds-backup.plist.template \
  > ~/Library/LaunchAgents/dev.mokkenstorm.reeds-backup.plist
plutil -lint ~/Library/LaunchAgents/dev.mokkenstorm.reeds-backup.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mokkenstorm.reeds-backup.plist
```

`PATH` must contain `sqlite3` and `rsync`. The job reads
`~/.config/reeds/backup.env` and `~/.config/reeds/config.toml` (for `db`), and
whispers through the `reeds-cli` in the release. It logs to
`~/Library/Logs/reeds-backup.log`. macOS may prompt once for access to the
removable volume; approve it, or the first scheduled run fails and whispers.

## Manual run

```sh
~/.local/share/reeds/app/reeds-backup          # per backup.env (bin/reeds-backup from a checkout)
REEDS_DB=$PWD/reeds.db REEDS_BACKUP_DEST=/tmp/reeds-bk REEDS_BACKUP_REQUIRE_MOUNT= bin/reeds-backup
launchctl kickstart gui/$(id -u)/dev.mokkenstorm.reeds-backup
```

Tests: `test/reeds-backup.test.sh`.

## Restore

```sh
launchctl bootout gui/$(id -u)/dev.mokkenstorm.reeds
gunzip -c <dest>/reeds-<date>.db.gz > reeds.db
rm -f reeds.db-wal reeds.db-shm
sqlite3 reeds.db 'PRAGMA integrity_check'
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mokkenstorm.reeds.plist
```

Move the damaged `reeds.db` aside first if you want to keep it. The stale
`-wal` and `-shm` files must go: replaying an old WAL onto a restored file
corrupts it.

## Retention

`REEDS_BACKUP_KEEP_DAYS` days of dailies (default 30), pruned by modification time on the exact name pattern
`<prefix>-????-??-??.db.gz`. Rerunning on the same day overwrites that day's file.
The script never uses `rsync --delete` and never moves or copies onto the
volume with anything but `rsync`.
