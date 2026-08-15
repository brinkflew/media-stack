#!/usr/bin/env bash
# ==============================================================================
# Prove that a backup restores, rather than that it exists
# ------------------------------------------------------------------------------
# RUNS ON THE WORKSTATION. `restic snapshots` says a snapshot exists.
# `restic check` says the repository is internally consistent. Neither says the
# thing that matters: that what comes out is a config tree the stack can start
# from.
#
# This had never been tested. The only restore ever performed was during the
# migration on 2026-08-12, from a backup taken before Caddy, Pocket ID and
# Tinyauth existed - so every claim about restoring sign-on and TLS was
# inference.
#
# WHAT IT ASSERTS, and why each one is a real failure that a passing
# `restic check` would not catch:
#
#   Caddy's certificates and ACME account. 192 KB that cannot be regenerated
#   without hitting Let's Encrypt rate limits. Under Docker these were
#   root-owned inside the container and rsync skipped them silently.
#
#   Every SQLite database opens and passes an integrity check. The backup
#   snapshots them through SQLite's backup API precisely because a copied WAL
#   database can be missing commits - but nothing has ever confirmed the output
#   of that is loadable.
#
#   No -wal, -shm, lock or pid files came through. A restored qBittorrent Qt
#   lockfile records a pid, a hostname and a machine id; on a host where the
#   hostname does not match, Qt assumes the lock is held and qBittorrent exits
#   one second after starting, logging only "termination initiated".
#
#   The load-bearing databases are present BY NAME. "some databases restored" is
#   not the same claim as "Pocket ID's passkey records restored", and only the
#   second one means sign-on still works.
#
# Usage:
#   bin/verify-restore.sh                  the local repository
#   bin/verify-restore.sh --repo offsite   the off-site one, which is now the
#                                          only copy that survives nvme0n1
#   bin/verify-restore.sh --deep           also read 5% of the pack data back
#   bin/verify-restore.sh --keep           leave the restored tree in place
# ==============================================================================

set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"

REPO_KIND=local
DEEP=""
KEEP=""
while [ $# -gt 0 ]; do
	case "${1:-}" in
		--repo)    REPO_KIND="${2:-}"; shift 2 ;;
		--repo=*)  REPO_KIND="${1#*=}"; shift ;;
		--deep)    DEEP=1; shift ;;
		--keep)    KEEP=1; shift ;;
		*) echo "verify-restore: unknown argument: $1" >&2; exit 2 ;;
	esac
done

fails=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
die()  { printf '\033[31mverify-restore: %s\033[0m\n' "$*" >&2; exit 1; }

command -v restic >/dev/null || die "restic is not on PATH"

case "$REPO_KIND" in
	local)
		export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-$HOME/backups/home-server}"
		export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/home-server.pw}"
		;;
	offsite)
		env_file="${HOME_SERVER_OFFSITE_ENV:-$HOME/.config/restic/home-server-offsite.env}"
		[ -s "$env_file" ] || die "no off-site config at $env_file"
		set -a
		# shellcheck source=/dev/null  # a runtime override, not a fixed path
		. "$env_file"
		set +a
		export RESTIC_PASSWORD_FILE="${HOME_SERVER_OFFSITE_PW:-$HOME/.config/restic/home-server-offsite.pw}"
		;;
	*) die "--repo takes 'local' or 'offsite', not '$REPO_KIND'" ;;
esac
[ -s "$RESTIC_PASSWORD_FILE" ] || die "no repository password at $RESTIC_PASSWORD_FILE"

# WHERE THE SCRATCH TREE GOES IS NOT A DETAIL. config/ is 5.5 GB, and on this
# workstation /tmp is tmpfs with 7.6 GB free out of 15 GB of RAM - so the
# obvious default would restore the whole tree INTO MEMORY, and either OOM or
# leave the machine swapping. Default to somewhere disk-backed and let TMPDIR
# override it deliberately.
SCRATCH="${TMPDIR:-$HOME/.cache/home-server}"
mkdir -p "$SCRATCH" 2>/dev/null

# Fail before downloading gigabytes rather than partway through. restic reports
# the snapshot's size, so the requirement is knowable up front; ask for 1.5x it
# to leave room for the restore's own bookkeeping.
# Snapshots written by older restic have no summary, so fall back to a figure
# comfortably above what config/ has ever been rather than skipping the check.
need_mb=$(restic snapshots --latest 1 --json 2>/dev/null \
	| jq -r '[.[].summary.total_bytes_processed // 0] | max // 0' \
	| awk '{n = ($1 / 1048576) * 1.5; printf "%d", (n < 1 ? 9000 : n)}')
have_mb=$(df -Pm "$SCRATCH" | awk 'NR==2 {print $4}')
fstype=$(findmnt -no FSTYPE --target "$SCRATCH" 2>/dev/null)
if [ "${need_mb:-0}" -gt 0 ] && [ "${have_mb:-0}" -lt "${need_mb}" ]; then
	die "$SCRATCH has ${have_mb}M free, this needs about ${need_mb}M.
  Point TMPDIR somewhere with room:  TMPDIR=/var/tmp $0 $*"
fi
case "$fstype" in
	tmpfs|ramfs)
		die "$SCRATCH is $fstype - restoring $(( need_mb / 1024 ))G there would go into RAM.
  Point TMPDIR at disk-backed storage:  TMPDIR=\$HOME/.cache $0 $*" ;;
esac
echo "  scratch: $SCRATCH ($fstype, ${have_mb}M free, needs ~${need_mb}M)"

TARGET=$(mktemp -d "$SCRATCH/home-server-restore.XXXXXX") || die "cannot create a scratch directory"
cleanup() { [ -n "$KEEP" ] || rm -rf "$TARGET"; }
trap cleanup EXIT

say "repository: $RESTIC_REPOSITORY"
restic snapshots --latest 1 --compact || die "cannot read the repository"

# ------------------------------------------------------------------------------
say "Integrity"
# ------------------------------------------------------------------------------
# Structure only by default. --read-data-subset actually pulls pack files back
# and re-hashes them, which is the only thing that detects bit rot or a
# truncated upload - but it costs bandwidth against object storage.
if [ -n "$DEEP" ]; then
	if restic check --read-data-subset=5%; then
		ok "repository consistent, 5% of data re-read"
	else
		bad "restic check FAILED"
	fi
else
	if restic check; then
		ok "repository structure consistent"
	else
		bad "restic check FAILED"
	fi
fi

# ------------------------------------------------------------------------------
say "Restoring the latest snapshot"
# ------------------------------------------------------------------------------
restic restore latest --target "$TARGET" >/dev/null || die "restore failed"

# restic recreates the full original path, so config/ lands several levels down
# under whatever staging directory it was backed up from. Find it rather than
# guess the depth - the server and the workstation stage from different paths.
CONFIG=$(find "$TARGET" -maxdepth 6 -type d -name config -print -quit)
[ -n "$CONFIG" ] || die "no config/ directory in the restored tree"
echo "  restored $(du -sh "$CONFIG" | cut -f1) to ${CONFIG#"$TARGET"}"

# ------------------------------------------------------------------------------
say "Caddy"
# ------------------------------------------------------------------------------
certs=$(find "$CONFIG/caddy" -name '*.crt' 2>/dev/null | wc -l)
keys=$(find "$CONFIG/caddy" -name '*.key' 2>/dev/null | wc -l)
if [ "$certs" -gt 0 ] && [ "$keys" -gt 0 ]; then
	ok "$certs certificates, $keys private keys"
else
	bad "no certificates or keys - a restore would re-issue, or hit rate limits"
fi
# The ACME account key is separate from the certificates and is what lets Caddy
# renew rather than register again.
if find "$CONFIG/caddy" -type d -name acme 2>/dev/null | grep -q .; then
	ok "ACME account directory present"
else
	bad "no ACME account directory"
fi

# ------------------------------------------------------------------------------
say "Exclusions"
# ------------------------------------------------------------------------------
# BEFORE the database check, not after, and that ordering is load-bearing.
# Opening a WAL-mode SQLite database creates a -shm and a -wal beside it even
# for a read-only connection, so checking afterwards finds files this script
# created and blames the backup for them. It did exactly that on first run: 40
# strays, all 0 bytes, all with the mtime of the verification rather than of the
# snapshot. Assert what the snapshot CONTAINS before touching any of it.
#
# These are excluded by the backup on purpose, so finding one means the exclude
# list is not doing its job - and each of them breaks a service quietly. The
# worst is qBittorrent's Qt lockfile, which records a pid, a hostname and a
# machine id; restored where the hostname differs, Qt assumes the lock is held
# and qBittorrent exits one second after starting, logging only "termination
# initiated".
strays=$(find "$CONFIG" \( -name '*-wal' -o -name '*-shm' -o -name '*-journal' \
	-o -name 'lockfile' -o -name '*.lock' -o -name '*.pid' \) 2>/dev/null)
if [ -z "$strays" ]; then
	ok "no stale WAL, lock or pid files in the snapshot"
else
	bad "excluded files present in the snapshot:"
	echo "$strays" | sed "s|$CONFIG|  config|" | head -10
fi

# ------------------------------------------------------------------------------
say "Databases"
# ------------------------------------------------------------------------------
# Identified by magic bytes, not extension, exactly as bin/snapshot-databases.sh
# does - Tdarr and Jellyfin both use .db for things that are not SQLite. The two
# scripts have to agree about what a database is, or this verifies a different
# set than the backup captured.
#
# python3's sqlite3 module rather than the sqlite3 CLI, which is not installed
# on this workstation.
if ! python3 - "$CONFIG" <<'PY'
import os, sqlite3, sys

config = sys.argv[1]
MAGIC = b"SQLite format 3\x00"
ok = bad = 0
names = []

for root, dirs, files in os.walk(config):
    for name in files:
        path = os.path.join(root, name)
        try:
            with open(path, "rb") as fh:
                if fh.read(16) != MAGIC:
                    continue
        except OSError:
            continue
        rel = os.path.relpath(path, config)
        names.append(rel)
        try:
            # immutable=1, not merely mode=ro. A read-only connection to a
            # WAL-mode database still CREATES a -shm and a -wal beside it,
            # because SQLite needs the shared-memory index to read one. That
            # pollutes the very tree the exclusions check inspects. immutable=1
            # promises the file cannot change, so SQLite skips WAL recovery and
            # touches nothing - which is exactly true of a restored snapshot.
            con = sqlite3.connect("file:%s?immutable=1" % path, uri=True)
            result = con.execute("PRAGMA integrity_check").fetchone()[0]
            con.close()
        except Exception as exc:
            print("  \033[31mFAIL\033[0m  %s does not open: %s" % (rel, exc))
            bad += 1
            continue
        if result == "ok":
            ok += 1
        else:
            print("  \033[31mFAIL\033[0m  %s: %s" % (rel, result))
            bad += 1

if ok:
    print("  \033[32mPASS\033[0m  %d databases pass integrity_check" % ok)
if not names:
    print("  \033[31mFAIL\033[0m  no SQLite databases in the restored tree at all")
    bad += 1

# By name, because "some databases restored" is not the claim worth making.
# Each of these is a thing whose loss is invisible until someone tries to use it.
WANTED = {
    "sonarr/sonarr.db":         "Sonarr's series, history and download clients",
    "radarr/radarr.db":         "Radarr's films and custom format scores",
    "prowlarr/prowlarr.db":     "the indexer definitions and their credentials",
    "pocket-id/pocket-id.db":   "EVERY REGISTERED PASSKEY - sign-on dies without it",
    "jellyfin/data/data/jellyfin.db": "Jellyfin's users and watch state",
}
for rel, what in WANTED.items():
    if any(n == rel or n.endswith("/" + rel) for n in names):
        print("  \033[32mPASS\033[0m  %s" % rel)
    else:
        print("  \033[31mFAIL\033[0m  %s is MISSING - %s" % (rel, what))
        bad += 1

sys.exit(1 if bad else 0)
PY
then
	fails=$((fails + 1))
fi

echo
if [ -n "$KEEP" ]; then
	printf 'restored tree left at %s\n' "$TARGET"
fi
if [ "$fails" -gt 0 ]; then
	printf '\033[31m%d check(s) FAILED - this backup would not fully restore\033[0m\n' "$fails"
	exit 1
fi
printf '\033[32mthis snapshot restores\033[0m\n'
