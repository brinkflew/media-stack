#!/usr/bin/env bash
# ==============================================================================
# Take consistent copies of every database under config/
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER. Called by bin/backup-config.sh over ssh; there is little
# reason to run it by hand.
#
# Copying a live SQLite file is not a backup. The applications run with
# write-ahead logging, so at any instant the .db on disk can be missing commits
# that live in the -wal, and a plain copy of the three files is only consistent
# if nothing writes between them. The *arr apps write constantly.
#
# SQLite's own backup API exists for exactly this: it takes a read lock, copies
# pages, and restarts if a writer interferes, producing a single file that is
# consistent as of one instant and needs no -wal alongside it. This walks
# config/, identifies databases by magic bytes rather than by extension - both
# Tdarr and Jellyfin use .db for things that are not SQLite - and snapshots each
# one into a shadow tree that the backup then overlays on top of the file copy.
#
# NOTE, because the sentence above used to read as though Tdarr had no SQLite at
# all: Tdarr 2.86 migrated off NeDB, and its real database is now a single
# genuine SQLite file at config/tdarr/server/Tdarr/DB2/SQL/database.db with a
# 15 MB -wal beside it. The magic-byte walk already picks it up, which is exactly
# why the test is on bytes and not on the extension - the non-SQLite .db files
# are still there alongside it.
#
# The shadow tree is deliberately NOT deleted between runs, so the pages restic
# already knows about stay stable and each run only transfers what changed.
# ==============================================================================

set -euo pipefail

CONFIG="${1:-/var/home-server/config}"
SHADOW="${2:-$HOME/.cache/home-server/db-snapshot}"
# The same file bin/backup-server.sh and bin/pre-update-snapshot.sh keep their
# markers in, for the reason the latter gives: bin/verify-host.sh reads one place.
STATE="${HOME_SERVER_BACKUP_STATE:-$HOME/.cache/home-server/backup-state}"

mkdir -p "$SHADOW"

# CAPTURED RATHER THAN FATAL, and the Postgres leg below is why. This script
# runs under `set -e` and the walk exits 1 if any single database failed, so with
# the obvious spelling one locked SQLite file would silently skip the cluster
# dump entirely - a night that loses Postgres because Bazarr was busy. The status
# is carried to the end instead, so both callers still see exactly what they saw.
rc=0
python3 - "$CONFIG" "$SHADOW" <<'PY' || rc=$?
import os, sqlite3, sys

config, shadow = sys.argv[1], sys.argv[2]
MAGIC = b"SQLite format 3\x00"

ok = failed = skipped = 0
total = 0

# Directories with nothing SQLite in them that are expensive or misleading to
# walk. prometheus/ is a time-series store: thousands of chunk files, none of
# which can pass the magic-byte test, so opening every one to read 16 bytes is
# pure cost inside a job deliberately throttled to IOWeight=20. Worse, its files
# vanish under compaction between listdir and open, and each one raises OSError
# and increments "unreadable" - a count that would then fluctuate nightly and
# mean nothing. It is snapshotted properly by its own admin API instead.
#
# windmill-db is the same argument reaching the same conclusion by a different
# route: it is Postgres, so nothing under it can EVER hold a SQLite header, and
# its files vanish under checkpoint rather than compaction. It is snapshotted by
# pg_dumpall instead - the only consistent copy of a running Postgres there is.
SKIP_DIRS = {"prometheus", "windmill-db"}

for root, dirs, files in os.walk(config):
    # Caddy's directories are root-owned and unreadable to this user; the
    # backup script pulls them out of the container instead.
    dirs[:] = [d for d in dirs
               if d not in SKIP_DIRS
               and os.access(os.path.join(root, d), os.R_OK | os.X_OK)]
    for name in files:
        src = os.path.join(root, name)
        if name.endswith(("-wal", "-shm", "-journal")):
            continue
        try:
            with open(src, "rb") as fh:
                if fh.read(16) != MAGIC:
                    continue
        except OSError:
            skipped += 1
            continue

        rel = os.path.relpath(src, config)
        dst = os.path.join(shadow, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            # Read-only source: this must never be able to modify a live
            # application database, whatever else goes wrong.
            source = sqlite3.connect("file:%s?mode=ro" % src, uri=True, timeout=30)
            target = sqlite3.connect(dst)
            with target:
                source.backup(target)
            target.close(); source.close()
            ok += 1
            total += os.path.getsize(dst)
        except Exception as exc:
            failed += 1
            print("  FAILED %s: %s" % (rel, exc), file=sys.stderr)

print("  snapshotted %d databases (%.1f MB), %d unreadable, %d failed"
      % (ok, total / 1e6, skipped, failed))
sys.exit(1 if failed else 0)
PY

# ------------------------------------------------------------------------------
# Postgres, which the walk above can never find
# ------------------------------------------------------------------------------
# windmill-db is the first database CONTAINER here, and nothing inside a PGDATA
# directory can hold a SQLite header - which is why SKIP_DIRS prunes it above and
# why bin/backup-server.sh excludes it from the file copy outright. pg_dumpall is
# what puts it in a backup at all: the only consistent copy of a running Postgres
# there is, and the exact counterpart of the SQLite backup API above.
#
# NOT RUNNING IS A SKIP, RUNNING AND FAILING IS FATAL, and the difference is not
# pedantry. bin/pre-update-snapshot.sh calls this as ExecStartPre= on
# podman-auto-update.service with no `-` prefix, so a non-zero exit here means the
# nightly container update does not happen. That is right for a dump that broke,
# and absurd for a fleet somebody deliberately stopped.
PGC=windmill-db
if ! command -v podman >/dev/null 2>&1; then
	# Distinguished from the skip below rather than folded into it: "no podman" is
	# a broken environment and "not running" is a normal one, and a message naming
	# the wrong one costs an afternoon.
	echo "  podman is not on PATH - no cluster dump attempted"
elif ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PGC"; then
	echo "  $PGC is not running - no cluster dump (this is not a failure)"
else
	dump="$SHADOW/$PGC/dumpall.sql"
	mkdir -p "$(dirname "$dump")"

	# THE SUPERUSER NAME COMES FROM THE CONTAINER, not from .env. It already knows
	# what initdb was given, so there is no second copy of the value to drift - and
	# the exec reaches postgres over the unix socket, where the image's own pg_hba
	# grants `trust`, so no password crosses a command line or an environment.
	#
	# umask IN A SUBSHELL, not chmod afterwards. pg_dumpall emits
	# `CREATE ROLE ... PASSWORD 'SCRAM-SHA-256$...'`, and once Windmill holds a
	# workspace the dump carries its secret store too. A chmod after the write
	# leaves a window in which a file full of credentials is world-readable. Same
	# idiom as the restic password files in bin/backup-server.sh.
	if ! ( umask 077; podman exec "$PGC" sh -c 'pg_dumpall -U "$POSTGRES_USER"' >"$dump.tmp" ); then
		rm -f "$dump.tmp"
		echo "  FAILED $PGC: pg_dumpall exited non-zero" >&2
		exit 1
	fi

	# THE COMPLETION MARKER IS THE TRUNCATION CHECK. A full disk, a killed exec and
	# a torn write do not reliably surface as a non-zero status through `podman
	# exec` and a shell redirect - all three do surface as a dump that stops early,
	# and this is pg_dumpall's last line.
	if ! tail -3 "$dump.tmp" | grep -q 'PostgreSQL database cluster dump complete'; then
		rm -f "$dump.tmp"
		echo "  FAILED $PGC: the dump has no completion marker - it is truncated" >&2
		exit 1
	fi

	mv "$dump.tmp" "$dump"
	echo "  dumped $PGC ($(wc -c <"$dump") bytes)"

	# THE MARKER IS WRITTEN HERE, AND ONLY ON A REAL DUMP. This is the only place
	# that can tell a dump from a skip: the exit status cannot, and neither caller
	# can. That matters because the shadow tree is never deleted and the `protect`
	# filter keeps last night's staged copy, so a stopped database leaves a dump
	# that is re-snapshotted nightly and looks current for ever. The file proves
	# existence; only this timestamp proves recency.
	#
	# Read-modify-write preserving every other key, the same block as
	# bin/pre-update-snapshot.sh, `|| true` included because of set -e above.
	# bin/backup-server.sh has to name this key in its carry-forward list, or the
	# 03:00 rewrite erases it minutes after this run wrote it.
	mkdir -p "$(dirname "$STATE")"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	{
		grep -vE '^windmill_dump_at=' "$STATE" 2>/dev/null || true
		echo "windmill_dump_at=$now"
	} >"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
fi

exit $rc
