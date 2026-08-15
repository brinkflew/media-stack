#!/usr/bin/env bash
# ==============================================================================
# Rename the project on the server: media-stack -> home-server
# ------------------------------------------------------------------------------
# RUNS ON THE WORKSTATION, and it has to: it renames the directory it would
# otherwise be running from. The surviving-file-descriptor argument is true and
# irrelevant - /var/media-stack -> /var/home-server is a same-filesystem
# rename(2), so an open fd keeps reading. What breaks is everything around it:
# the ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" idiom that six
# sibling scripts here use resolves to a stale path, $PWD becomes a dangling
# string, and this script's whole job is to invoke OTHER path-dependent scripts
# (render-env.sh, verify-host.sh, the greenboot wrapper) out of the real
# checkout. Driving it over ssh makes every step a fresh shell with no cwd
# inside the moving tree, and lets the confirmation prompt work.
#
# THIS FILE IS EXCLUDED FROM THE RENAME SED, deliberately. It is the one file
# that legitimately has to name both the old thing and the new one, which is why
# both are variables at the top rather than literals throughout.
#
# IT IS IDEMPOTENT BY DERIVED STATE, NOT BY A PROGRESS FILE. Every step carries
# a test read from the world, and that test is re-run AFTER the action - the
# rule this repository already learned twice, at verify-host.sh's ordering
# drop-in and backup-server.sh's delete probe: assert the effect, never the
# record. `ln -sf` without -n "succeeds" while creating entirely the wrong
# thing; only the post-condition catches it. Re-running after a partial failure
# is therefore always the correct response.
#
# THE STACK IS STOPPED THROUGHOUT, and that is a choice. Running containers hold
# their bind mounts by inode, so a live rename is invisible to them and looks
# free - but then every container is still running the OLD units against the OLD
# paths out of the OLD image, and the restart that would actually prove the new
# configuration just gets deferred to midnight, unattended, by
# podman-auto-update.timer. Worse, if quadlet generation fails - which it does
# SILENTLY - you are left with eighteen containers systemd no longer knows
# about. That is the half-migrated host this script exists to avoid, and trying
# to dodge a few minutes of downtime is what creates it.
#
# THE ONE HAZARD THAT IS NOT OBVIOUS: /etc/greenboot/check/required.d holds a
# symlink into the checkout. The moment the tree is renamed that symlink
# dangles, greenboot cannot exec it, and the NEXT BOOT IS RED - which, because
# the reboot lives inside the greenboot binary rather than in any unit file,
# rolls back a deployment that was never bad. An empty required.d is green by
# default; a dangling symlink in it is not. So it comes out BEFORE the rename
# and goes back after, and that ordering is not negotiable.
#
# Usage:
#   bin/migrate-rename.sh --dry-run   assert everything, change nothing
#   bin/migrate-rename.sh             the whole migration, with a confirmation
# ==============================================================================

set -uo pipefail

OLD="media-stack"
NEW="home-server"

HOST="${MEDIA_STACK_HOST:-home.local}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OLD_ROOT="/var/$OLD"
NEW_ROOT="/var/$NEW"

VERIFY_MAX=600
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
note() { printf '  \033[2m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mmigrate-rename: %s\033[0m\n' "$*" >&2; exit 1; }

# -n for the same reason reboot-host.sh gives: without it every probe would eat
# the confirmation before `read` ever saw it.
sshq() { ssh -n -o ConnectTimeout=10 "$HOST" "$@"; }

# step <description> <test-that-it-is-done> <action>
#
# The post-condition re-check is the whole point. An action that exits 0 has not
# necessarily done the thing.
step() {
	local desc="$1" done_test="$2" action="$3"
	if sshq "$done_test" >/dev/null 2>&1; then
		ok "$desc (already done)"
		return 0
	fi
	if [ -n "$DRY" ]; then
		printf '  \033[33mWOULD\033[0m  %s\n' "$desc"
		return 0
	fi
	sshq "$action" || die "$desc

  FAILED. Nothing here deletes data - every step is mv, ln or podman tag - so
  re-running this script is the correct response. It will skip what is already
  done and prove each skip rather than assuming it."
	sshq "$done_test" >/dev/null 2>&1 || die "$desc

  reported success but the state did not change. This is the failure mode the
  post-condition exists to catch; read the step and check by hand before
  re-running."
	ok "$desc"
}

# ------------------------------------------------------------------------------
say "Pre-flight on $HOST"
# ------------------------------------------------------------------------------
sshq true 2>/dev/null || die "cannot reach $HOST"

# The whole battery. Migrating an already-unhealthy host turns one problem into
# two and you will not know which caused which - reboot-host.sh's argument, and
# it applies with more force here because this touches more.
if sshq "test -x $OLD_ROOT/bin/verify-host.sh"; then
	if sshq "$OLD_ROOT/bin/verify-host.sh --quiet"; then
		ok "verify-host passes"
	else
		sshq "$OLD_ROOT/bin/verify-host.sh" 2>&1 | sed 's/^/  /'
		die "the host is not healthy - fix that before renaming anything"
	fi
elif sshq "test -x $NEW_ROOT/bin/verify-host.sh"; then
	ok "already migrated past the rename - verifying the new path instead"
	sshq "$NEW_ROOT/bin/verify-host.sh --quiet" || bad "verify-host does not pass yet"
else
	die "found neither $OLD_ROOT nor $NEW_ROOT - is this the right host?"
fi

# AMBIGUITY IS A REFUSAL, NOT A GUESS. If both names exist for any of the four
# trees, a previous run stopped somewhere unknowable and no script should pick.
for pair in "$OLD_ROOT:$NEW_ROOT" \
            "/var/lib/$OLD:/var/lib/$NEW" \
            "/var/backups/$OLD:/var/backups/$NEW" \
            "\$HOME/.cache/$OLD:\$HOME/.cache/$NEW"; do
	o="${pair%%:*}"; n="${pair##*:}"
	if sshq "test -e \"$o\" && test -e \"$n\""; then
		die "both $o and $n exist - refusing to guess which is authoritative"
	fi
done
ok "no old/new name collisions"

# A mv across a filesystem boundary is a 5.6 GB copy that can half-fill /var or
# be interrupted. One stat is cheap insurance.
if sshq "test -e $OLD_ROOT"; then
	d_var=$(sshq "stat -c %d /var")
	d_old=$(sshq "stat -c %d $OLD_ROOT")
	[ "$d_var" = "$d_old" ] || die "$OLD_ROOT is not on the same filesystem as /var - mv would copy, not rename"
	ok "$OLD_ROOT is on the same filesystem as /var"

	dirty=$(sshq "git -C $OLD_ROOT status --porcelain")
	[ -z "$dirty" ] || die "the server checkout is dirty:
$dirty"
	ok "server checkout is clean"
fi

sshq 'sudo -n true' 2>/dev/null || die "passwordless sudo does not work - /var/lib, /etc and the greenboot symlinks need it"
ok "sudo -n works"

# Renaming a restic repository mid-run leaves a lock in the OFF-SITE repo that
# the append-only key cannot remove.
# Match WHOLE WORDS. `case "$state" in *active*)` also matches "inactive",
# which is the substring trap that makes a refusal fire on a perfectly idle
# host - and a gate that always refuses is as useless as one that never does.
state=$(sshq "systemctl --user show $OLD-backup.service $NEW-backup.service -p ActiveState --value 2>/dev/null")
for s in $state; do
	case "$s" in
		active|activating|reloading|deactivating)
			die "a backup is $s - wait for it, or a lock is left off-site that the append-only key cannot clear" ;;
	esac
done
ok "no backup in flight"

# Both directories at once means the check would run twice.
if sshq "test -e /etc/greenboot/check/required.d/40-$OLD.sh && test -e /etc/greenboot/check/wanted.d/40-$OLD.sh"; then
	die "the greenboot check is in BOTH required.d and wanted.d - resolve that first"
fi

# Preserve where it actually is. reboot-when-staged.sh refuses unless the check
# is in required.d, so demoting it silently disarms the unattended reboot.
GB_DIR="required.d"
if sshq "test -e /etc/greenboot/check/wanted.d/40-$OLD.sh"; then
	GB_DIR="wanted.d"
fi
if sshq "test -e /etc/greenboot/check/$GB_DIR/40-$OLD.sh"; then
	ok "greenboot check lives in $GB_DIR"
else
	note "greenboot check not found under the old name (already migrated?)"
fi

if sshq "podman image exists localhost/$OLD/caddy:latest"; then
	ok "the built Caddy image is present (it will be retagged, not rebuilt)"
else
	note "localhost/$OLD/caddy:latest is absent - starting caddy will trigger a source build"
fi

if sshq "test -L \$HOME/.config/containers/containers.conf"; then
	ok "containers.conf symlink present"
else
	bad "containers.conf symlink is MISSING - healthcheck_events is not in force"
fi

# Do not collide with the nightly jobs.
h=$(sshq 'date +%-H'); dow=$(sshq 'date +%u')
case "$h" in
	23|0|2|3) die "it is ${h}:00 on the host - podman-auto-update runs at 00:00 and the backup at 03:00. Come back outside those hours." ;;
esac
[ "$dow" = "7" ] && [ "$h" -ge 5 ] && [ "$h" -le 9 ] && die "the unattended reboot window is open (Sunday 05:00-09:00)"
ok "outside the nightly job windows"

enc=$(sshq 'nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader,nounits' | tr -d ' ' | tr '\n' '+')
if [ "$(echo "${enc%+}" | tr '+' ' ' | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}')" -eq 0 ]; then
	ok "encoder idle - nothing mid-transcode"
else
	bad "encoder is busy (${enc%+}) - a transcode will be killed"
fi

running=$(sshq 'podman ps -q | wc -l')
ok "$running containers running now - this is the number the end must reproduce"

# The workstation side has to be pushed, because the server pulls it.
if [ -z "$DRY" ]; then
	[ -z "$(git -C "$REPO" status --porcelain)" ] || die "the WORKSTATION checkout is dirty - commit before migrating"
	git -C "$REPO" grep -qF "$NEW_ROOT" -- stacks/ >/dev/null 2>&1 \
		|| die "the workstation tree does not mention $NEW_ROOT in stacks/ - is the rename commit merged to main?"
fi

# Derive the container units from the quadlet filenames rather than hardcoding a
# list that will go stale, the same argument host/systemd/README.md makes about
# globbing the unit symlinks.
units=""
for f in "$REPO"/stacks/*/*; do
	b="${f##*/}"
	case "$b" in
		*.container) units="$units ${b%.container}.service" ;;
		*.pod)       units="$units ${b%.pod}-pod.service" ;;
	esac
done
note "will stop:$units"

# ------------------------------------------------------------------------------
if [ -z "$DRY" ]; then
say "Confirm"
# ------------------------------------------------------------------------------
cat <<EOF

  This stops every container on $HOST, renames the checkout that config/
  (5.6 GB) lives inside, and edits root-owned files under /etc.

  Nothing below deletes data. Every step is mv, ln or podman tag, so the
  recovery from any failure is to run this script again - it derives what is
  already done from the world rather than from a journal.

  The stack will be down for a few minutes.

EOF
read -r -p "  Type 'rename' to proceed: " reply
[ "$reply" = "rename" ] || die "aborted"
fi

# ------------------------------------------------------------------------------
say "Quiesce"
# ------------------------------------------------------------------------------
# Disable BEFORE the rename, while the old unit names still resolve. Rename
# first and the five links in timers.target.wants/ dangle permanently, while
# `is-enabled` cheerfully keeps answering "enabled" for a unit that is gone.
step "timers disabled" \
	"! systemctl --user list-unit-files '$OLD-*.timer' 2>/dev/null | grep -q enabled" \
	"systemctl --user disable --now $OLD-backup.timer $OLD-caddy-build.timer $OLD-promote.timer $OLD-reboot.timer $OLD-verify.timer 2>/dev/null; true"

# It fires at 00:00 with jitter and would restart containers underneath us.
step "podman-auto-update.timer stopped" \
	"! systemctl --user is-active podman-auto-update.timer >/dev/null 2>&1" \
	"systemctl --user stop podman-auto-update.timer"

# THE HAZARD. Out before the rename, back in after.
step "greenboot symlinks removed (they would dangle across the rename)" \
	"! test -e /etc/greenboot/check/$GB_DIR/40-$OLD.sh && ! test -e /etc/greenboot/red.d/50-record-red-boot.sh" \
	"sudo -n rm -f /etc/greenboot/check/$GB_DIR/40-$OLD.sh /etc/greenboot/red.d/50-record-red-boot.sh"

# Fetch now so the merge later is purely local and cannot fail on DNS. A fetch
# writes only inside .git and touches no working-tree file.
if [ -n "$DRY" ]; then
	printf '  \033[33mWOULD\033[0m  %s\n' "fetch origin"
elif sshq "test -d $OLD_ROOT/.git"; then
	sshq "git -C $OLD_ROOT fetch origin" || die "could not fetch origin - fix the network before going further"
	ok "origin fetched (the merge below is local only)"
fi

step "containers stopped" \
	"test \"\$(podman ps -q | wc -l)\" -eq 0" \
	"systemctl --user stop $units"

# The .network units are RemainAfterExit oneshots holding podman networks; they
# are deliberately left alone, and a network cannot be modified in place anyway.
if [ -z "$DRY" ]; then
	left=$(sshq 'podman ps --format "{{.Names}}"')
	if [ -n "$left" ]; then
		note "still up after the unit stop: $left"
		sshq 'podman stop --all --time 30' >/dev/null 2>&1
		left=$(sshq 'podman ps --format "{{.Names}}"')
		[ -z "$left" ] || die "these containers will not stop: $left"
	fi
	ok "nothing running"
fi

# ------------------------------------------------------------------------------
say "Rename"
# ------------------------------------------------------------------------------
# -T ON EVERY ONE. Without it, if the destination somehow exists as a directory,
# mv puts the source INSIDE it and you get /var/home-server/media-stack - the
# half-migrated host, delivered by a missing flag.
#
# AND NO restorecon. SELinux labels are xattrs on the inode and survive
# rename(2) untouched: the checkout stays var_t, and config/ and apps/caddy keep
# the container_file_t that the :z/:Z mounts gave them. A well-meant
# `restorecon -R` here would strip those off 5.6 GB of config/ and no container
# could read its own data.
step "checkout moved to $NEW_ROOT" \
	"test -d $NEW_ROOT && ! test -e $OLD_ROOT" \
	"sudo -n mv -T $OLD_ROOT $NEW_ROOT"

step "/var/lib/$NEW moved" \
	"test -d /var/lib/$NEW && ! test -e /var/lib/$OLD" \
	"sudo -n mv -T /var/lib/$OLD /var/lib/$NEW"

step "/var/backups/$NEW moved" \
	"test -d /var/backups/$NEW && ! test -e /var/backups/$OLD" \
	"sudo -n mv -T /var/backups/$OLD /var/backups/$NEW"

# backup-state carries offsite_pruned_at, which verify-host.sh ages - so this is
# a move, never a recreate.
step "the cache directory moved to \$HOME/.cache/$NEW" \
	"test -d \$HOME/.cache/$NEW && ! test -e \$HOME/.cache/$OLD" \
	"mv -T \$HOME/.cache/$OLD \$HOME/.cache/$NEW"

# -n ON EVERY ln. Without it, `ln -sf target link` where link is an existing
# symlink-to-directory DEREFERENCES it and creates stacks/common/common inside
# the checkout - which dirties the tree permanently, leaves the real symlink
# dangling, and makes generation emit nothing, all with no error output.
step "quadlet directory symlinks retargeted" \
	"test \"\$(readlink \$HOME/.config/containers/systemd/common)\" = \"$NEW_ROOT/stacks/common\"" \
	"for d in common infra media torrent; do ln -sfn $NEW_ROOT/stacks/\$d \$HOME/.config/containers/systemd/\$d; done"

step "containers.conf symlink retargeted" \
	"test \"\$(readlink \$HOME/.config/containers/containers.conf)\" = \"$NEW_ROOT/host/containers/containers.conf\"" \
	"ln -sfn $NEW_ROOT/host/containers/containers.conf \$HOME/.config/containers/containers.conf"

# ------------------------------------------------------------------------------
say "Content"
# ------------------------------------------------------------------------------
if [ -z "$DRY" ]; then
	sshq "git -C $NEW_ROOT merge --ff-only origin/main" || die "the fast-forward failed - 'git -C $NEW_ROOT status' will say why"
	dirty=$(sshq "git -C $NEW_ROOT status --porcelain")
	[ -z "$dirty" ] || die "the checkout is dirty after the merge:
$dirty"
	ok "checkout fast-forwarded to origin/main"
fi

# Glob, do not list. host/systemd/README.md argues this at length: the old
# hand-written list gained media-stack-caddy-build and nobody appended it.
step "host unit symlinks relinked" \
	"test -L \$HOME/.config/systemd/user/$NEW-verify.timer" \
	"for u in $NEW_ROOT/host/systemd/*.service $NEW_ROOT/host/systemd/*.timer; do ln -sfn \"\$u\" \$HOME/.config/systemd/user/; done"

# The resumability net: -lname targets exactly the links this migration orphans
# and nothing else, so it is safe to run any number of times.
step "orphaned unit symlinks swept" \
	"test -z \"\$(find \$HOME/.config/systemd/user -maxdepth 2 -xtype l -lname '/var/$OLD/*' -print -quit)\"" \
	"find \$HOME/.config/systemd/user -maxdepth 2 -xtype l -lname '/var/$OLD/*' -delete"

# Renaming a unit out from under a RUNNING timer leaves the OLD name behind in
# systemd's runtime state as not-found/failed - five ghosts that no file
# explains, that survive daemon-reload, and that verify-host.sh correctly
# reports as failed units for ever. Only reset-failed clears them, and it can
# only run once the new names are linked.
step "the old unit names cleared from systemd's runtime state" \
	"test \"\$(systemctl --user list-units --failed --no-legend | grep -c $OLD || true)\" -eq 0" \
	"systemctl --user reset-failed"

step "greenboot symlinks restored" \
	"test -x /etc/greenboot/check/$GB_DIR/40-$NEW.sh && test -x /etc/greenboot/red.d/50-record-red-boot.sh" \
	"sudo -n ln -sfn $NEW_ROOT/host/greenboot/40-$NEW.sh /etc/greenboot/check/$GB_DIR/40-$NEW.sh &&
	 sudo -n ln -sfn $NEW_ROOT/host/greenboot/50-record-red-boot.sh /etc/greenboot/red.d/50-record-red-boot.sh"

# A COPY, not a symlink: journald.conf is parsed by PID 1, which SELinux will
# not let read var_t. The failure is convincingly silent - `systemctl cat`
# prints the file happily and no AVC is logged.
step "journald drop-in installed under the new name" \
	"test -f /etc/systemd/journald.conf.d/10-$NEW.conf && ! test -e /etc/systemd/journald.conf.d/10-$OLD.conf" \
	"sudo -n install -D -m 0644 $NEW_ROOT/host/journald/10-$NEW.conf /etc/systemd/journald.conf.d/10-$NEW.conf &&
	 sudo -n rm -f /etc/systemd/journald.conf.d/10-$OLD.conf &&
	 sudo -n systemctl restart systemd-journald"

step "greenboot ordering drop-in renamed" \
	"test -f /etc/systemd/system/greenboot-healthcheck.service.d/10-$NEW.conf && ! test -e /etc/systemd/system/greenboot-healthcheck.service.d/10-$OLD.conf" \
	"sudo -n install -D -m 0644 /etc/systemd/system/greenboot-healthcheck.service.d/10-$OLD.conf /etc/systemd/system/greenboot-healthcheck.service.d/10-$NEW.conf &&
	 sudo -n rm -f /etc/systemd/system/greenboot-healthcheck.service.d/10-$OLD.conf &&
	 sudo -n systemctl daemon-reload"

# Otherwise /run/motd.d/ holds two blocks until the next reboot, one of them
# permanently stale and carrying its own confident timestamp - the failure
# verify-host.sh calls "the failure that hides every other failure".
step "stale MOTD removed" \
	"! test -e /run/motd.d/40-$OLD.motd" \
	"sudo -n rm -f /run/motd.d/40-$OLD.motd"

if [ -z "$DRY" ]; then
	sshq "$NEW_ROOT/bin/render-env.sh" || die "render-env.sh failed"
	# ASSERT THE RENDERED OUTPUT, NEVER THE EXIT CODE. render-env.sh exits 0 on
	# any decrypt containing DOMAIN=, including a decrypt of a commit that
	# predates the sops edit - and quadlets expand an undefined ${VAR} to the
	# empty string silently.
	for kv in "DOCKER_VOLUME_CONFIG=$NEW_ROOT/config" \
	          "DOCKER_VOLUME_CACHE=$NEW_ROOT/cache" \
	          "BACKUP_LOCAL_REPOSITORY=/var/backups/$NEW" \
	          "DOCKER_VOLUME_MEDIA=/mnt/media"; do
		sshq "grep -qx '$kv' $NEW_ROOT/.env" || die ".env does not contain '$kv' after rendering - the server may be on the wrong commit"
	done
	ok ".env rendered with the new paths (and /mnt/media unmoved)"
fi

# ------------------------------------------------------------------------------
say "Generate"
# ------------------------------------------------------------------------------
if [ -z "$DRY" ]; then
	sshq 'systemctl --user daemon-reload' || die "daemon-reload failed"

	# THE MOST IMPORTANT ASSERTION IN THE SCRIPT. Quadlet generation failure is
	# silent: one wrong symlink and it emits nothing at all, while the reload
	# exits 0. Never trust the exit code here.
	frag=$(sshq 'systemctl --user show caddy.service -p FragmentPath --value')
	case "$frag" in
		/run/user/*/systemd/generator/*) ok "quadlet generated caddy.service" ;;
		*) die "quadlet did NOT generate caddy.service (FragmentPath=${frag:-none}).
  Check: readlink \$HOME/.config/containers/systemd/*" ;;
	esac

	# Direct proof that generation read the RENAMED tree.
	envf=$(sshq 'systemctl --user show sonarr.service -p EnvironmentFiles --value')
	case "$envf" in
		*"$NEW_ROOT/.env"*) ok "generated units read $NEW_ROOT/.env" ;;
		*) die "sonarr.service reads '$envf' - the quadlet directory symlinks are wrong" ;;
	esac

	n=$(sshq 'ls /run/user/1000/systemd/generator/*.service 2>/dev/null | wc -l')
	[ "${n:-0}" -ge 22 ] || die "only ${n:-0} generated units, expected at least 22 - quadlet did not see every directory"
	ok "$n units generated"
fi

# ------------------------------------------------------------------------------
say "Start"
# ------------------------------------------------------------------------------
# RETAG, DO NOT REBUILD. A quadlet .build unit only fires when its image is
# ABSENT - and caddy.build is an xcaddy SOURCE build that pulls a Go toolchain,
# carries TimeoutStartSec=900, and has Pull=newer so it fetches whatever caddy:2
# is today. That build can genuinely fail, which is the entire point of the
# weekly timer: an incompatible release fails THERE, while the running container
# keeps serving. Letting it fire inside the migration inverts that - the failure
# now happens with nothing serving, and the rename gets blamed for an upstream
# Go compile error. Retagging is instant, offline, and keeps the exact bytes
# that were serving five minutes ago.
step "Caddy image retagged" \
	"podman image exists localhost/$NEW/caddy:latest" \
	"podman tag localhost/$OLD/caddy:latest localhost/$NEW/caddy:latest"

if [ -z "$DRY" ] && sshq "podman image exists localhost/$OLD/caddy:latest"; then
	a=$(sshq "podman image inspect -f '{{.Id}}' localhost/$OLD/caddy:latest")
	b=$(sshq "podman image inspect -f '{{.Id}}' localhost/$NEW/caddy:latest")
	[ "$a" = "$b" ] || die "the retag did not produce the same image"
	ok "the retagged image is the same bytes"
fi

step "timers enabled" \
	"systemctl --user is-enabled $NEW-verify.timer >/dev/null 2>&1" \
	"systemctl --user enable --now $NEW-backup.timer $NEW-caddy-build.timer $NEW-promote.timer $NEW-reboot.timer $NEW-verify.timer"

step "podman-auto-update.timer re-armed" \
	"systemctl --user is-active podman-auto-update.timer >/dev/null 2>&1" \
	"systemctl --user start podman-auto-update.timer"

if [ -z "$DRY" ]; then
	# gluetun first: Notify=healthy means its start blocks until the tunnel is
	# up, and the two pod members have no network stack without it.
	sshq 'systemctl --user start gluetun' || bad "gluetun did not start"
	sshq "systemctl --user start $units" || bad "some units did not start - the battery below will say which"
	ok "start issued"
fi

# ------------------------------------------------------------------------------
say "Verify"
# ------------------------------------------------------------------------------
if [ -n "$DRY" ]; then
	printf '\n\033[1mdry run - nothing was changed\033[0m\n'
	exit 0
fi

verified=""
started=$(date +%s)
printf '  waiting for the stack to settle'
while [ $(( $(date +%s) - started )) -lt "$VERIFY_MAX" ]; do
	sleep 20
	if sshq "$NEW_ROOT/bin/verify-host.sh --quiet" >/dev/null 2>&1; then
		verified=1
		break
	fi
	printf '.'
done
printf '\n'

sshq "$NEW_ROOT/bin/verify-host.sh" 2>&1 | sed 's/^/  /'

say "Assertions"
now=$(sshq 'podman ps -q | wc -l')
if [ "$now" = "$running" ]; then
	ok "$now containers running (was $running)"
else
	bad "$now containers running, expected $running"
fi

if [ -z "$(sshq 'systemctl --user list-units --failed --no-legend')" ]; then
	ok "no failed user units"
else
	bad "there are failed user units"
fi

if [ -z "$(sshq 'podman ps --filter health=unhealthy --format "{{.Names}}"')" ]; then
	ok "no unhealthy containers"
else
	bad "unhealthy containers present"
fi

dangling=$(sshq "find \$HOME/.config/systemd/user \$HOME/.config/containers /etc/greenboot -xtype l -print 2>/dev/null")
if [ -z "$dangling" ]; then
	ok "no dangling symlinks"
else
	bad "dangling symlinks:
$dangling"
fi

# The highest-coverage single command here: it proves the required.d symlink
# resolves and is executable, that the renamed env-var defaults inside the
# wrapper are right, that verify-host.sh --greenboot passes, and that
# /var/lib/home-server is writable by root.
if sshq "sudo -n /etc/greenboot/check/$GB_DIR/40-$NEW.sh" >/dev/null 2>&1; then
	ok "the greenboot check runs and passes"
	sshq "cat /var/lib/$NEW/boot-state" | sed 's/^/    /'
else
	bad "the greenboot check does not pass - the next boot would be RED"
fi

# Prove restic opens the renamed repository without waiting for 03:00.
if sshq "set -a; . $NEW_ROOT/.env; set +a;
         RESTIC_REPOSITORY=\"\$BACKUP_LOCAL_REPOSITORY\" RESTIC_PASSWORD=\"\$BACKUP_LOCAL_PASSWORD\" \
         ~/.local/bin/restic snapshots --latest 1 --compact" >/dev/null 2>&1; then
	ok "restic opens $NEW_ROOT's repository at the new path"
else
	bad "restic could not open the local repository - check BACKUP_LOCAL_REPOSITORY"
fi

if [ -n "$verified" ]; then
	printf '\n\033[32mdone\033[0m\n'
	cat <<EOF

  Follow-ups, none of them urgent:
    - podman rmi localhost/$OLD/caddy:latest      (after one weekly rebuild)
    - rewrite the restic snapshot identity        (see bin/README.md)
    - delete bin/migrate-rename.sh and fold the procedure into host/RUNBOOK.md
EOF
else
	printf '\n\033[31mthe battery did not pass within %ss - read it above\033[0m\n' "$VERIFY_MAX"
	exit 1
fi
