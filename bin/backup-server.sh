#!/usr/bin/env bash
# ==============================================================================
# Back up config/ from the server itself, nightly
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, from home-server-backup.timer. This is the backup that
# actually happens: bin/backup-config.sh pulls from the workstation and is
# therefore only as frequent as someone being at home, which meant a fortnight
# away was a fortnight with no backups.
#
# TWO DESTINATIONS, AND THEY PROTECT AGAINST DIFFERENT THINGS:
#
#   /var/backups/home-server   Local, fast, no credentials, no network. Covers a
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
# AND IT PROVES THAT EVERY NIGHT rather than trusting it. The restriction rests
# on an absence - there is no Deny statement, only nothing granting delete
# outside locks/ - so a policy that has quietly stopped constraining anything is
# indistinguishable from one that works. The probe writes a 0-byte object and
# tries to delete it, expecting AccessDenied, and records the result where
# bin/verify-host.sh can see it go stale. See section 5.
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
STAGING="${HOME_SERVER_STAGING:-/var/backups/staging}"
STATE="${HOME_SERVER_BACKUP_STATE:-$HOME/.cache/home-server/backup-state}"
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
#
# /prometheus/ IS EXCLUDED HERE AND RE-ADDED IN STEP 3b, and the reason is not
# that a live TSDB copies badly - it is that copying it at all breaks this whole
# script. Prometheus deletes WAL segments at every checkpoint and deletes source
# blocks after every compaction; rsync exits 24 when a file it has already
# enumerated vanishes, and the line below ends in `|| die`. So one routine
# compaction inside the backup window would abort the run BEFORE the Caddy
# assertion, the database snapshots, both restic legs and the marker write - and
# the symptom would be backup.local_age going stale, three scripts away from the
# cause.
#
# NOTE WHY NONE OF THE PATTERNS ABOVE ALREADY COVERED IT, because it is the same
# shape as the shellcheck leg that silently never ran: Prometheus names its lock
# file `lock`, which `lockfile` does not match and `*.lock` does not match
# either, and its write-ahead log is a DIRECTORY called `wal/`, which `*-wal`
# does not match. A pattern list that quietly matches nothing looks exactly like
# one that works.
#
# The `protect` filter is what stops --delete-excluded removing last night's
# staged copy, which would otherwise force a full re-copy of a growing TSDB
# every night onto the disk this job deliberately throttles itself against.
# Verified rather than assumed: with --exclude alone the staged directory is
# deleted, and with the filter it survives.
say "staging $CONFIG"
mkdir -p "$STAGING/config" || die "cannot create $STAGING"
rsync -a --delete --delete-excluded --info=stats1 \
	--exclude='*-wal' --exclude='*-shm' --exclude='*-journal' \
	--exclude='*.log' --exclude='*.log.[0-9]*' --exclude='*.txt.[0-9]*' \
	--exclude='jellyfin/cache/' --exclude='jellyfin/log/' --exclude='jellyfin/transcodes/' \
	--exclude='tdarr/logs/' --exclude='tdarr/server/Tdarr/Backups/' \
	--exclude='*/logs/' \
	--exclude='lockfile' --exclude='*.lock' --exclude='*.pid' \
	--filter='protect /prometheus/' --exclude='/prometheus/' \
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
if [ "$certs" -eq 0 ] || [ "$keys" -eq 0 ]; then
	die "no Caddy certificates captured"
fi

# ------------------------------------------------------------------------------
# 3. Consistent database snapshots, laid over the file copy
# ------------------------------------------------------------------------------
# A live SQLite file is not a backup: the applications run with WAL, so the .db
# on disk can be missing commits that live in the -wal. See snapshot-databases.sh.
say "snapshotting live databases"
"$ROOT/bin/snapshot-databases.sh" "$CONFIG" || die "database snapshot failed"
rsync -a "$HOME/.cache/home-server/db-snapshot/" "$STAGING/config/" || die "overlay failed"

# ------------------------------------------------------------------------------
# 3b. A consistent copy of the metrics store
# ------------------------------------------------------------------------------
# Same argument as the databases above, different mechanism: a live TSDB has an
# in-memory head block and an open WAL, so a file copy is torn by construction.
# Prometheus's admin API makes a snapshot out of HARDLINKS, so it is instant,
# costs no disk, and is consistent at the instant it is taken.
#
# podman exec is the only route to it. There is no published port and
# net-metrics carries isolate=true, so the host cannot reach the container any
# other way - the same escape hatch verify-host.sh's promq uses, and the reason
# the Caddyfile can close /api/v1/admin/* to the outside without closing this.
#
# FAILURE HERE IS RECORDED, NOT FATAL. Losing metrics history is not losing
# config/, so this must never abort the run that carries the *arr databases and
# Caddy's private keys. But it is ASSERTED rather than assumed, for the reason
# the certificate count above exists: a silently skipped step leaves a backup
# that looks complete and contains no metrics at all.
say "snapshotting the metrics store"
tsdb_ok=""
tsdb_dir="$CONFIG/prometheus"
if [ ! -d "$tsdb_dir" ]; then
	echo "    no metrics store at $tsdb_dir - nothing to snapshot"
else
	# PROMETHEUS NEVER REAPS snapshots/. --storage.tsdb.retention.size manages
	# blocks and knows nothing about these, so one left behind by an interrupted
	# run keeps its hardlinked blocks alive after compaction would have freed
	# them - real, growing disk inside the directory metrics.tsdb_size measures,
	# reported as "retention is not being enforced". Clear stale ones first, so
	# a killed run repairs itself on the next pass rather than accumulating.
	find "$tsdb_dir/snapshots" -mindepth 1 -maxdepth 1 -type d -mmin +180 \
		-exec rm -rf {} + 2>/dev/null

	tsdb_name=$(podman exec prometheus wget -q -O - --post-data='' \
		http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot 2>/dev/null \
		| jq -r '.data.name // empty' 2>/dev/null)
	if [ -z "$tsdb_name" ]; then
		echo "    could not snapshot - the metrics store is absent from this backup"
	elif ! rsync -a --delete "$tsdb_dir/snapshots/$tsdb_name/" \
		"$STAGING/config/prometheus/"; then
		echo "    could not stage the snapshot"
		rm -rf "${tsdb_dir:?}/snapshots/${tsdb_name:?}"
	else
		blocks=$(find "$STAGING/config/prometheus" -name meta.json 2>/dev/null | wc -l)
		echo "    $blocks blocks staged"
		rm -rf "${tsdb_dir:?}/snapshots/${tsdb_name:?}"
		[ "$blocks" -gt 0 ] && tsdb_ok=1
	fi
fi

# ------------------------------------------------------------------------------
# 4. Local repository
# ------------------------------------------------------------------------------
# Passwords go into files in a private directory rather than onto a command
# line. `restic copy` needs two of them at once, and the obvious spelling -
# --password-command "echo $PASS" - puts both in the process table, where any
# process on the box can read them out of ps.
umask 077
PWDIR=$(mktemp -d /run/user/"$(id -u)"/home-server-backup.XXXXXX 2>/dev/null) \
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
restic backup $DRY --tag home-server --tag config --host home-server "$STAGING/config" \
	|| die "local backup failed"

if [ -z "$DRY" ]; then
	# Keeps a year of history for a few GB. The daily tier matters most: the
	# damage this protects against is usually noticed within a week.
	say "local retention"
	restic forget --tag home-server --prune \
		--keep-daily 7 --keep-weekly 4 --keep-monthly 12 || die "local prune failed"
fi

# FILTER BY HOST AND PATH, do not just take --latest 1. That flag means "the
# latest per group", and restic groups by host AND paths - so in a repository
# holding more than one chain it returns several rows and .[0] is whichever came
# back first, not the newest. The off-site repository holds two chains (this
# machine stages at /var/backups/staging/config, the workstation at
# ~/.cache/home-server/staging/config), and recording the wrong one made the
# marker name a two-day-old snapshot from the other chain.
snapshot_id() {  # <extra restic args...>
	restic "$@" snapshots --host home-server --path "$STAGING/config" \
		--latest 1 --json 2>/dev/null | jq -r '.[0].short_id // empty'
}

local_id=$(snapshot_id)

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
policy_ok=""
policy_broken=""
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
		offsite_id=$(snapshot_id -r "$BACKUP_OFFSITE_REPOSITORY" --password-file "$PWDIR/offsite")
	else
		offsite_failed=1
		printf '\033[31m  off-site copy FAILED - the local snapshot is still good\033[0m\n'
	fi

	# --------------------------------------------------------------------------
	# The append-only guarantee, asserted rather than remembered
	# --------------------------------------------------------------------------
	# Driving the backup from the server spends part of the old security model -
	# the credential now lives on the machine being backed up - so what is left
	# has to be enforced rather than assumed: the Scaleway key may write, and may
	# delete ONLY under locks/, which restic needs to release its own lock.
	#
	# That restriction rests on an ABSENCE. There is no Deny statement to read;
	# delete outside locks/ is impossible because nothing grants it. A policy
	# that has silently stopped constraining anything therefore looks exactly
	# like one that works, and it lives outside this repository and outside every
	# backup - a console edit, a key rotation that reattaches a broader IAM
	# policy, or a Scaleway-side policy migration would all widen it with nothing
	# here noticing.
	#
	# AUTHORIZATION IS EVALUATED BEFORE OBJECT EXISTENCE, which is what makes
	# this cheap: a DeleteObject refused by policy is 403, an allowed one is 204,
	# and the two are distinguishable without destroying anything. The
	# alternative - `restic forget --keep-last 1 --prune`, which is what
	# CLAUDE.md documents - proves the same thing by pruning the off-site
	# repository to a single snapshot on its way to telling you.
	#
	# THE PUT IS NOT OPTIONAL. `rclone deletefile` stats the object first, so
	# against a key that does not exist it fails at the HEAD and never issues the
	# DELETE - a probe that passes for ever while testing nothing. One small
	# object therefore lives at the probe key, overwritten each night. It sits at
	# the top level, where restic reads only `config`, rather than in one of the
	# prefixes it enumerates.
	#
	# Two rclone details, both found by the probe failing rather than by reading
	# the manual, and both of which made the PUT fail while looking like a
	# credentials problem:
	#
	#   --s3-no-check-bucket  rclone otherwise issues CreateBucket before its
	#                         first upload. The append-only key cannot create
	#                         buckets - correctly - so every write failed with
	#                         `operation error S3: CreateBucket`, which reads
	#                         like the key is broken rather than like rclone
	#                         asking for something it does not need.
	#   a NON-EMPTY body      `rclone rcat` refuses empty stdin outright with
	#                         "nothing to read from standard input", so the
	#                         obvious </dev/null writes nothing at all.
	#
	# rclone rather than a hand-rolled SigV4 request because uCore already ships
	# it, and the credentials go in through RCLONE_S3_* rather than argv for the
	# same reason the restic passwords go into files: anything on a command line
	# is readable out of the process table. The leading colon in `:s3:` means an
	# ad-hoc backend, so no rclone config file is consulted or needed.
	say "off-site delete denial"
	if ! command -v rclone >/dev/null 2>&1; then
		printf '\033[33m  inconclusive: rclone is not installed\033[0m\n'
	else
		# s3:https://s3.fr-par.scw.cloud/home-server-backup -> endpoint + bucket
		repo_url=${BACKUP_OFFSITE_REPOSITORY#s3:}
		repo_rest=${repo_url#*://}
		probe_host=${repo_rest%%/*}
		probe_bucket=${repo_rest#*/}
		export RCLONE_CONFIG=""          # no config file exists or is wanted
		export RCLONE_S3_PROVIDER=Scaleway
		export RCLONE_S3_NO_CHECK_BUCKET=true
		export RCLONE_S3_ACCESS_KEY_ID="$BACKUP_OFFSITE_ACCESS_KEY"
		export RCLONE_S3_SECRET_ACCESS_KEY="$BACKUP_OFFSITE_SECRET_KEY"
		export RCLONE_S3_ENDPOINT="${repo_url%%://*}://$probe_host"
		# Scaleway signs with the region named in the endpoint host.
		probe_region=$(printf '%s' "$probe_host" | awk -F. '/^s3\./ { print $2 }')
		[ -z "$probe_region" ] || export RCLONE_S3_REGION="$probe_region"

		probe=":s3:$probe_bucket/${HOME_SERVER_DELETE_PROBE_KEY:-home-server-delete-probe}"
		if ! printf 'delete-denial probe\n' \
			| rclone rcat "$probe" >/dev/null 2>"$PWDIR/probe.err"; then
			# Cannot even write, so nothing was tested. Not a finding on its own:
			# the copy above would have failed too, and does say so.
			printf '\033[33m  inconclusive: could not write the probe object\033[0m\n'
			sed 's/^/    /' "$PWDIR/probe.err" >&2
		elif rclone deletefile --retries 1 --low-level-retries 1 \
			"$probe" >/dev/null 2>"$PWDIR/probe.err"; then
			policy_broken=1
			printf '\033[31m  THE OFF-SITE KEY CAN DELETE outside locks/\033[0m\n'
			printf '\033[31m  The append-only guarantee is GONE. Check the bucket policy\033[0m\n'
			printf '\033[31m  AND the IAM policy - Scaleway ANDs the two.\033[0m\n'
		elif grep -qiE 'accessdenied|forbidden|403' "$PWDIR/probe.err"; then
			policy_ok=1
			echo "    delete refused with AccessDenied - the restriction holds"
		else
			# A network blip must not read as a broken policy, so anything that
			# is not an explicit refusal is inconclusive and leaves the previous
			# marker in place to age out on its own.
			printf '\033[33m  inconclusive: the delete failed for another reason\033[0m\n'
			sed 's/^/    /' "$PWDIR/probe.err" >&2
		fi
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
		# Write fresh on success, carry the old line forward otherwise - the
		# same idiom as the off-site keys below, so a night the metrics store
		# could not be snapshotted reads as STALE rather than as never.
		if [ -n "$tsdb_ok" ]; then
			echo "tsdb_snapshot_at=$now"
		else
			grep -E '^tsdb_snapshot_at=' "$STATE" 2>/dev/null
		fi
		if [ -n "$offsite_id" ]; then
			echo "offsite_snapshot=$offsite_id"
			echo "offsite_at=$now"
		else
			# Preserve any previous off-site timestamp rather than dropping it,
			# so one failed night reads as "stale" and not as "never ran".
			grep -E '^offsite_(snapshot|at)=' "$STATE" 2>/dev/null
		fi
		# Written only on a CONFIRMED refusal. An inconclusive probe preserves
		# the old timestamp rather than dropping it, so one unreachable night
		# reads as "stale" in verify-host.sh and not as "never checked" - and a
		# genuine drift still surfaces once the value ages past the ceiling.
		if [ -n "$policy_ok" ]; then
			echo "offsite_policy_ok_at=$now"
		else
			grep -E '^offsite_policy_ok_at=' "$STATE" 2>/dev/null
		fi
		grep -E '^offsite_pruned_at=' "$STATE" 2>/dev/null
		# WRITTEN BY A DIFFERENT JOB, CARRIED FORWARD BY THIS ONE. The
		# pre-update snapshot runs as ExecStartPre= on
		# podman-auto-update.service at ~00:00; this block rewrites the state
		# file whole at 03:00. Without this line that marker is erased three
		# hours after it is written, every night - and backup.pre_update_age
		# would report the pre-update snapshot as having stopped running while
		# it was in fact running perfectly. Same shape as the off-site keys
		# above: name every key that has to survive, because the default is
		# that it does not.
		grep -E '^pre_update_db_at=' "$STATE" 2>/dev/null
	} >"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
fi

say "snapshots"
restic snapshots --compact 2>/dev/null | tail -4

# Exit non-zero only AFTER the marker is written, so the unit goes red and the
# MOTD still knows the local copy is current. The backups themselves have all
# completed by here: a policy regression is a security failure, not a reason to
# lose a night's backup, so it is reported at the end rather than up front.
[ -z "$policy_broken" ] \
	|| die "the off-site key CAN DELETE outside locks/ - the append-only guarantee is gone"
[ -z "$offsite_failed" ] || die "the off-site copy failed - the local one is current"
