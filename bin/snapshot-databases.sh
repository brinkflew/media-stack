#!/usr/bin/env bash
# ==============================================================================
# Take consistent copies of every SQLite database under config/
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

mkdir -p "$SHADOW"

python3 - "$CONFIG" "$SHADOW" <<'PY'
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
SKIP_DIRS = {"prometheus"}

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
