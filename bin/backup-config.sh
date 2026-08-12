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
# It also matters right now for a specific reason: config/ lives on nvme0n1p3,
# which the uCore install wipes. This is what makes that install recoverable.
#
# THREE THINGS THIS DOES THAT A PLAIN rsync DOES NOT, each of which otherwise
# produces a backup that looks complete and is not:
#
#   1. Caddy's /data is root-owned INSIDE its container and unreadable to the
#      ssh user. rsync skips it with a permission error that is easy to miss in
#      the noise. It is 192KB and contains every TLS private key and the ACME
#      account key - without it a restore silently re-issues certificates, or
#      hits Let's Encrypt rate limits and does not.
#
#   2. Live SQLite databases are snapshotted through SQLite's backup API rather
#      than copied. See bin/snapshot-databases.sh.
#
#   3. -wal and -shm files are excluded. They belong to the file copy, not to
#      the consistent snapshot that overwrites it, and restoring a stale -wal
#      next to a newer .db is worse than having neither.
#
# Usage:  bin/backup-config.sh [--dry-run]
# ==============================================================================

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

REMOTE="${MEDIA_STACK_HOST:-home}"
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
  --exclude='caddy/' \
  "$REMOTE:$REMOTE_CONFIG/" "$STAGING/config/"
# caddy/ is excluded rather than merely tolerated. Its subdirectories are
# root-owned and unreadable to this user, so rsync would exit 23 on every run -
# a real error, permanently expected, which is the fastest way to teach yourself
# to ignore this script's exit code. Step 2 repopulates it in full.

# ------------------------------------------------------------------------------
# 2. Caddy, out of the container
# ------------------------------------------------------------------------------
# `docker exec` runs as root inside the namespace, which is the only way to read
# this without a sudo password on the server.
echo "==> extracting Caddy state from the container"
for d in data config; do
  mkdir -p "$STAGING/config/caddy/$d"
  ssh "$REMOTE" "docker exec caddy tar -C /$d -cf - ." \
    | tar -xf - -C "$STAGING/config/caddy/$d"
done
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
restic backup $DRY --tag media-stack --tag config \
  --host "$REMOTE" "$STAGING/config"

if [ -z "$DRY" ]; then
  # Keeps a year of history for a few GB. The daily tier matters most: the
  # damage this protects against is usually noticed within a week.
  echo "==> pruning old snapshots"
  restic forget --tag media-stack --prune \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 12
fi

echo
restic snapshots --compact | tail -5
