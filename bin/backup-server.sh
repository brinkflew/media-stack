#!/usr/bin/env bash
# ==============================================================================
# Back up config/ from the server itself, nightly
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, from media-stack-backup.timer. This is the backup that
# actually happens: bin/backup-config.sh pulls from the workstation and is
# therefore only as frequent as someone being at home, which meant a fortnight
# away was a fortnight with no backups.
#
# TWO DESTINATIONS, AND THEY PROTECT AGAINST DIFFERENT THINGS:
#
#   /var/backups/media-stack   Local, fast, no credentials, no network. Covers a
#                              bad change, a bad restore, an application
#                              corrupting its own database. It is on the SAME
#                              DISK as config/, so it does NOT survive nvme0n1
#                              failing. That is deliberate - the media disk is
#                              kept for media - and it is why the off-site leg
#                              below runs every night rather than opportunistically.
#
#   Scaleway Object Storage    The copy that survives the disk, the machine and
#                              the building.
#
# THE OFF-SITE KEY CANNOT DELETE, AND THAT IS THE WHOLE SECURITY ARGUMENT.
# Everything else here used to depend on the server holding no backup
# credentials at all. Driving the schedule from the server spends part of that,
# so what is left has to be enforced rather than assumed: the Scaleway
# application key is scoped to PutObject/GetObject/ListBucket, with DeleteObject
# denied everywhere except the locks/ prefix restic needs to release its own
# lock. A compromised server can therefore ADD data and never destroy history.
#
# Which is why this script never prunes the off-site repository. It could not
# anyway - the calls would 403 - but the retention has to happen somewhere, so
# it happens on the workstation, which holds the admin key. See
# bin/backup-offsite.sh. Without that the off-site repository grows for ever.
#
# The server does hold the off-site repository PASSWORD, so it can read its own
# older snapshots. That is unavoidable for writing to a restic repository, and it
# leaks nothing the server does not already have, other than superseded secrets.
#
# Usage:  bin/backup-server.sh [--dry-run]
# ==============================================================================

set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${DOCKER_VOLUME_CONFIG:-$ROOT/config}"
STAGING="${MEDIA_STACK_STAGING:-/var/backups/staging}"
STATE="${MEDIA_STACK_BACKUP_STATE:-$HOME/.cache/media-stack/backup-state}"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

die() { printf '\033[31mbackup-server: %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Runnable by hand as well as from the unit, which passes the same file through
# EnvironmentFile=. .env is mode 600 and holds the passwords.
if [ -z "${BACKUP_LOCAL_REPOSITORY:-}" ] && [ -f "$ROOT/.env" ]; then
	set -a
	# shellcheck disable=SC1091
	. "$ROOT/.env"
	set +a
fi

command -v restic >/dev/null || die "restic is not on PATH - see host/RUNBOOK.md step 12"
[ -d "$CONFIG" ]             || die "no config tree at $CONFIG"
[ -n "${BACKUP_LOCAL_REPOSITORY:-}" ] || die "BACKUP_LOCAL_REPOSITORY is not set - run bin/render-env.sh"
[ -n "${BACKUP_LOCAL_PASSWORD:-}" ]   || die "BACKUP_LOCAL_PASSWORD is not set"

# ------------------------------------------------------------------------------
# 1. Stage a copy with the exclusions applied
# ------------------------------------------------------------------------------
# Same shape as bin/backup-config.sh, and the same exclusion list, because
# bin/verify-restore.sh asserts against both repositories and they have to agree
# about what a good snapshot contains.
#
# Excludes are only for things that regenerate on their own. Anything merely
# LARGE is kept: Tdarr's DB2 is 3.8 GB, but "regenerable" there means rescanning
# a 7.3 TB library, and restic deduplicates it across snapshots.
say "staging $CONFIG"
mkdir -p "$STAGING/config" || die "cannot create $STAGING"
rsync -a --delete --delete-excluded --info=stats1 \
	--exclude='*-wal' --exclude='*-shm' --exclude='*-journal' \
	--exclude='*.log' --exclude='*.log.[0-9]*' --exclude='*.txt.[0-9]*' \
	--exclude='jellyfin/cache/' --exclude='jellyfin/log/' --exclude='jellyfin/transcodes/' \
	--exclude='tdarr/logs/' --exclude='tdarr/server/Tdarr/Backups/' \
	--exclude='*/logs/' \
	--exclude='lockfile' --exclude='*.lock' --exclude='*.pid' \
	"$CONFIG/" "$STAGING/config/" || die "rsync failed"

# ------------------------------------------------------------------------------
# 2. Verify Caddy's state came through
# ------------------------------------------------------------------------------
# The one part of config/ that cannot be regenerated without hitting Let's
# Encrypt rate limits, and the one most likely to be silently skipped by a
# permission change. Counted every run rather than assumed.
certs=$(find "$STAGING/config/caddy" -name '*.crt' 2>/dev/null | wc -l)
keys=$(find "$STAGING/config/caddy" -name '*.key' 2>/dev/null | wc -l)
echo "    $certs certificates, $keys private keys"
[ "$certs" -gt 0 ] && [ "$keys" -gt 0 ] || die "no Caddy certificates captured"

# ------------------------------------------------------------------------------
# 3. Consistent database snapshots, laid over the file copy
# ------------------------------------------------------------------------------
# A live SQLite file is not a backup: the applications run with WAL, so the .db
# on disk can be missing commits that live in the -wal. See snapshot-databases.sh.
say "snapshotting live databases"
"$ROOT/bin/snapshot-databases.sh" "$CONFIG" || die "database snapshot failed"
rsync -a "$HOME/.cache/media-stack/db-snapshot/" "$STAGING/config/" || die "overlay failed"

# ------------------------------------------------------------------------------
# 4. Local repository
# ------------------------------------------------------------------------------
# Passwords go into files in a private directory rather than onto a command
# line. `restic copy` needs two of them at once, and the obvious spelling -
# --password-command "echo $PASS" - puts both in the process table, where any
# process on the box can read them out of ps.
umask 077
PWDIR=$(mktemp -d /run/user/"$(id -u)"/media-stack-backup.XXXXXX 2>/dev/null) \
	|| PWDIR=$(mktemp -d) || die "cannot create a private directory for the passwords"
trap 'rm -rf "$PWDIR"' EXIT
printf '%s' "$BACKUP_LOCAL_PASSWORD" >"$PWDIR/local"

export RESTIC_REPOSITORY="$BACKUP_LOCAL_REPOSITORY" RESTIC_PASSWORD_FILE="$PWDIR/local"

say "local: $RESTIC_REPOSITORY"
restic cat config >/dev/null 2>&1 || {
	echo "  not initialised - creating it"
	restic init || die "could not initialise the local repository"
}

# A FIXED host tag, not $(hostname). `restic forget` groups by host, so a
# snapshot tagged with whatever the machine calls itself today splits one
# machine's history into separate retention groups, each pruned independently
# and neither holding the full chain. It also has to match what the workstation
# writes, or the two repositories disagree about which chain is which.
restic backup $DRY --tag media-stack --tag config --host media-stack "$STAGING/config" \
	|| die "local backup failed"

if [ -z "$DRY" ]; then
	# Keeps a year of history for a few GB. The daily tier matters most: the
	# damage this protects against is usually noticed within a week.
	say "local retention"
	restic forget --tag media-stack --prune \
		--keep-daily 7 --keep-weekly 4 --keep-monthly 12 || die "local prune failed"
fi

local_id=$(restic snapshots --latest 1 --json 2>/dev/null | jq -r '.[0].short_id // empty')

# ------------------------------------------------------------------------------
# 5. Off-site copy
# ------------------------------------------------------------------------------
# NOT CONFIGURED and CONFIGURED BUT BROKEN are different, and the difference has
# to be in the guard rather than in the error. "No credentials at all" is the
# state between adding these variables and creating the Scaleway key, and
# failing the unit nightly for it teaches someone to ignore a red unit. A key
# that is present and rejected is a real failure and must be loud.
#
# So the test covers the ACCESS KEY, not just the repository. Getting this wrong
# is what made the first run fail: the repository and password were in sops and
# the key was still empty, so it tried and 403'd.
#
# Either way, staleness is the real backstop: bin/verify-host.sh FAILS when the
# off-site copy is more than 72h old, so a skip that goes on too long surfaces
# there whatever this script decides.
offsite_id=""
offsite_failed=""
if [ -z "${BACKUP_OFFSITE_REPOSITORY:-}" ] || [ -z "${BACKUP_OFFSITE_PASSWORD:-}" ] \
	|| [ -z "${BACKUP_OFFSITE_ACCESS_KEY:-}" ] || [ -z "${BACKUP_OFFSITE_SECRET_KEY:-}" ]; then
	printf '\n\033[33m  off-site is not configured yet - skipping\033[0m\n'
	printf '  Create the append-only Scaleway key and add it to secrets/env.sops.env.\n'
	printf '  bin/verify-host.sh will FAIL on this in 72h regardless.\n'
elif [ -n "$DRY" ]; then
	printf '\n  (dry run - not copying off-site)\n'
else
	say "off-site: $BACKUP_OFFSITE_REPOSITORY"
	printf '%s' "$BACKUP_OFFSITE_PASSWORD" >"$PWDIR/offsite"
	export AWS_ACCESS_KEY_ID="${BACKUP_OFFSITE_ACCESS_KEY:-}"
	export AWS_SECRET_ACCESS_KEY="${BACKUP_OFFSITE_SECRET_KEY:-}"

	# copy is idempotent - snapshots already present are skipped by ID - so this
	# is safe to re-run and cheap when nothing has changed. It re-encrypts blob
	# by blob, which is why the destination has its own password.
	#
	# NO forget, NO prune, NO init. The key cannot delete, and it should not be
	# able to; retention happens on the workstation.
	# NOT `|| die`. A failed off-site leg must not discard the record of a
	# successful local one: the first run did exactly that, and verify-host.sh
	# would then have reported "no local backup has EVER been recorded" while a
	# perfectly good 5.4 GiB snapshot sat in /var/backups. Note the failure,
	# write the marker, exit non-zero at the end.
	if restic -r "$BACKUP_OFFSITE_REPOSITORY" --password-file "$PWDIR/offsite" \
		copy --from-repo "$RESTIC_REPOSITORY" --from-password-file "$PWDIR/local"; then
		offsite_id=$(restic -r "$BACKUP_OFFSITE_REPOSITORY" --password-file "$PWDIR/offsite" \
			snapshots --latest 1 --json 2>/dev/null | jq -r '.[0].short_id // empty')
	else
		offsite_failed=1
		printf '\033[31m  off-site copy FAILED - the local snapshot is still good\033[0m\n'
	fi
fi

# ------------------------------------------------------------------------------
# 6. Tell the MOTD
# ------------------------------------------------------------------------------
# bin/verify-host.sh reads this. Without it, "the backup has not run for nine
# days" and "everything is fine" look identical from an ssh session, which is
# the failure mode this whole exercise exists to remove.
if [ -z "$DRY" ]; then
	mkdir -p "$(dirname "$STATE")"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	{
		echo "local_snapshot=$local_id"
		echo "local_at=$now"
		if [ -n "$offsite_id" ]; then
			echo "offsite_snapshot=$offsite_id"
			echo "offsite_at=$now"
		else
			# Preserve any previous off-site timestamp rather than dropping it,
			# so one failed night reads as "stale" and not as "never ran".
			grep -E '^offsite_(snapshot|at)=' "$STATE" 2>/dev/null
		fi
		grep -E '^offsite_pruned_at=' "$STATE" 2>/dev/null
	} >"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
fi

say "snapshots"
restic snapshots --compact 2>/dev/null | tail -4

# Exit non-zero only AFTER the marker is written, so the unit goes red and the
# MOTD still knows the local copy is current.
[ -z "$offsite_failed" ] || die "the off-site copy failed - the local one is current"
