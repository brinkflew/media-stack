#!/usr/bin/env bash
# ==============================================================================
# Back up the server's config/ into a restic repository
# ------------------------------------------------------------------------------
# RUNS ON THE WORKSTATION and pulls, rather than running on the server and
# pushing. The server needs no credentials for the backup destination and no
# route to it, so compromising the server does not get you the backups.
#
# config/ is the only part of this system that is not reproducible from git.
# /mnt/media is 7.3TB of re-downloadable media on a disk with no redundancy and
# is deliberately not backed up; config/ holds the things that cannot be
# recreated - Pocket ID's passkey records, Caddy's certificates and ACME
# account, the *arr databases, Jellyfin's users and watch state, qBittorrent's
# torrent state.
#
# SINCE 2026-08-14 THIS IS NO LONGER THE PRIMARY BACKUP. bin/backup-server.sh
# runs on the server nightly and covers both the local and the off-site copy,
# because a backup that only runs when someone is at home is not a schedule. This
# script is the THIRD copy: a different machine, a different repository, a
# different password, which is what survives the server being compromised
# outright. Run it when you are home; nothing depends on it being frequent.
#
# THREE THINGS THIS DOES THAT A PLAIN rsync DOES NOT, each of which otherwise
# produces a backup that looks complete and is not:
#
#   1. Caddy's certificates are asserted present, not assumed. Under Docker its
#      /data was root-owned inside the container and rsync skipped it with a
#      permission error easy to miss in the noise; rootless Podman maps container
#      root to the service user, so it copies normally now. The count is still
#      checked every run, because it is 192KB containing every TLS private key
#      and the ACME account key - without it a restore silently re-issues
#      certificates, or hits Let's Encrypt rate limits and does not.
#
#   2. Live SQLite databases are snapshotted through SQLite's backup API rather
#      than copied. See bin/snapshot-databases.sh.
#
#   3. -wal and -shm files are excluded. They belong to the file copy, not to
#      the consistent snapshot that overwrites it, and restoring a stale -wal
#      next to a newer .db is worse than having neither.
#
#   4. Lock files are excluded, for the same reason and with a nastier symptom.
#      This backup is taken with the stack RUNNING, so it captures live locks.
#      qBittorrent's Qt lockfile records the pid, the hostname and a machine id;
#      restored onto a machine where the hostname does not match, Qt cannot tell
#      whether the owning process is alive and conservatively assumes the lock is
#      held. qBittorrent then exits one second after starting, logging only
#      "termination initiated" - no error, no warning, nothing naming the lock.
#      It cost an hour after the migration.
#
# Usage:  bin/backup-config.sh [--dry-run]
# ==============================================================================

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# home.local, not home: `home` resolves to the WAN address and hairpins back
# through the router, which is both slower for a 5GB mirror and a dependency
# this script does not need. The LAN route is direct.
REMOTE="${MEDIA_STACK_HOST:-home.local}"
REMOTE_CONFIG="/var/media-stack/config"
REPO="${RESTIC_REPOSITORY:-$HOME/backups/media-stack}"
PWFILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/media-stack.pw}"
STAGING="${MEDIA_STACK_STAGING:-$HOME/.cache/media-stack/staging}"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

command -v restic >/dev/null || { echo "backup: restic not on PATH" >&2; exit 1; }
[ -f "$PWFILE" ]            || { echo "backup: no repository password at $PWFILE" >&2; exit 1; }
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PWFILE"

# ------------------------------------------------------------------------------
# 1. Mirror the readable tree
# ------------------------------------------------------------------------------
# Excludes are only for things that are regenerated on their own. Anything
# merely LARGE is kept: Tdarr's DB2 is 3.8GB, but "regenerable" there means
# rescanning a 7.3TB library, and restic deduplicates it across snapshots.
mkdir -p "$STAGING/config"
echo "==> mirroring $REMOTE:$REMOTE_CONFIG"
rsync -a --delete --delete-excluded --info=stats1 \
  --exclude='*-wal' --exclude='*-shm' --exclude='*-journal' \
  --exclude='*.log' --exclude='*.log.[0-9]*' --exclude='*.txt.[0-9]*' \
  --exclude='jellyfin/cache/' --exclude='jellyfin/log/' --exclude='jellyfin/transcodes/' \
  --exclude='tdarr/logs/' --exclude='tdarr/server/Tdarr/Backups/' \
  --exclude='*/logs/' \
  --exclude='lockfile' --exclude='*.lock' --exclude='*.pid' \
  "$REMOTE:$REMOTE_CONFIG/" "$STAGING/config/"
# caddy/ used to be excluded here and re-extracted with `docker exec caddy tar`,
# because under Docker its subdirectories were root-owned and unreadable to this
# user - rsync exited 23 on every run. Rootless Podman maps container root to the
# service user, so /data is now plainly owned by `core` and rsync just copies it.
# The special case is gone; the assertion below is not.

# ------------------------------------------------------------------------------
# 2. Verify Caddy's state came through
# ------------------------------------------------------------------------------
# This is the one part of config/ that cannot be regenerated without hitting
# Let's Encrypt rate limits, and the one most likely to be silently skipped by a
# permission change. Count it every run rather than assume the rsync covered it.
certs=$(find "$STAGING/config/caddy" -name '*.crt' | wc -l)
keys=$(find "$STAGING/config/caddy" -name '*.key' | wc -l)
echo "    $certs certificates, $keys private keys"
# A backup missing these restores into a server that cannot serve TLS. Fail
# loudly rather than record a snapshot that looks fine.
[ "$certs" -gt 0 ] && [ "$keys" -gt 0 ] || { echo "backup: no Caddy certificates captured" >&2; exit 1; }

# ------------------------------------------------------------------------------
# 3. Consistent database snapshots, laid over the file copy
# ------------------------------------------------------------------------------
echo "==> snapshotting live databases"
ssh "$REMOTE" 'bash -s' < "$(dirname "${BASH_SOURCE[0]}")/snapshot-databases.sh"
rsync -a "$REMOTE:.cache/media-stack/db-snapshot/" "$STAGING/config/"

# ------------------------------------------------------------------------------
# 4. Into restic
# ------------------------------------------------------------------------------
restic snapshots >/dev/null 2>&1 || { echo "==> initialising repository at $REPO"; restic init; }

echo "==> backing up"
# A FIXED host tag, not $REMOTE. `restic forget` groups by host, so tagging
# snapshots with whichever ssh alias was used splits one machine's history into
# separate retention groups - each pruned independently, and neither holding the
# full chain. The alias is a route; this is an identity.
restic backup $DRY --tag media-stack --tag config \
  --host media-stack "$STAGING/config"

if [ -z "$DRY" ]; then
  # Keeps a year of history for a few GB. The daily tier matters most: the
  # damage this protects against is usually noticed within a week.
  echo "==> pruning old snapshots"
  restic forget --tag media-stack --prune \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 12
fi

echo
restic snapshots --compact | tail -5
