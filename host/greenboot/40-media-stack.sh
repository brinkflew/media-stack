#!/usr/bin/env bash
# ==============================================================================
# greenboot's health check: did THIS DEPLOYMENT come up correctly?
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as root, from greenboot-healthcheck.service, during the
# multi-user transaction. Symlinked into /etc/greenboot/check/{wanted,required}.d/
# - see host/greenboot/README.md for which, and why that distinction is the whole
# safety model.
#
# This is a wrapper, not a check. Every assertion lives in verify-host.sh
# --greenboot, which already draws the only line that matters: host-level state
# only, never the eighteen containers. greenboot has NO ordering against the user
# manager, so the stack is still starting when the verdict is rendered - a check
# that looked at containers would roll back a good deployment because Tdarr is
# slow.
#
# What the wrapper adds is the three things a check cannot do for itself:
#
#   a durable verdict   ExecMainExitTimestamp is runtime state and a reboot wipes
#                       it, which is a problem when the subject IS the reboot.
#                       Without a record on disk, "the last boot was healthy" and
#                       "nothing has ever checked" look identical.
#   a bounded runtime   nothing in verify-host.sh is timeout-wrapped, and two of
#                       its checks are rpm-ostree D-Bus round trips that block
#                       while rpm-ostreed is staging.
#   a refusal to guess  only an explicit FAIL is allowed to mean "bad
#                       deployment". See below - this is the important part.
#
# ONLY A CONFIRMED FAILURE COUNTS, which is the same rule the off-site policy
# probe follows and for the same reason. A rollback is expensive and, on a
# machine with no console, effectively irreversible if it loops. So a timeout, or
# a checkout that is not there, is recorded as inconclusive and exits 0: those
# are conditions a rollback cannot fix, and a health check that reverts the OS
# because /var/media-stack was missing would be doing harm confidently. The
# hourly battery still surfaces both, via the MOTD, at a moment someone can read
# it.
# ==============================================================================

set -uo pipefail

# systemd gives a system service LANG and PATH and nothing else. verify-host.sh
# now defaults HOME itself, but this runs before it and must not rely on that.
export HOME="${HOME:-/root}"
export PATH="/usr/local/bin:/usr/bin:/usr/sbin:/usr/local/sbin"

CHECK="${MEDIA_STACK_CHECK:-/var/media-stack/bin/verify-host.sh}"
STATE="${MEDIA_STACK_BOOT_STATE:-/var/lib/media-stack/boot-state}"
LIMIT="${MEDIA_STACK_GREENBOOT_TIMEOUT:-120}"

# ------------------------------------------------------------------------------
# The durable verdict
# ------------------------------------------------------------------------------
# Same shape as the backup state file: key=value, ISO-8601 UTC, written to a
# temporary and moved into place so a reader never sees a half-written file.
# red_boot_at is preserved rather than rewritten - it is set by the red.d hook
# and cleared by a human, and this run has nothing to say about it.
record() {  # <green|red|timeout|missing>
	local now booted_ver booted_sum status_json
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	status_json=$(rpm-ostree status --json 2>/dev/null)
	booted_ver=$(jq -r '.deployments[] | select(.booted) | .version // "?"' \
		<<<"$status_json" 2>/dev/null)
	booted_sum=$(jq -r '.deployments[] | select(.booted) | .checksum // "?"' \
		<<<"$status_json" 2>/dev/null | cut -c1-12)

	mkdir -p "$(dirname "$STATE")"
	{
		echo "greenboot_result=$1"
		echo "greenboot_checked_at=$now"
		echo "booted_version=${booted_ver:-?}"
		echo "booted_checksum=${booted_sum:-?}"
		grep -E '^red_boot_at=' "$STATE" 2>/dev/null
	} >"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
}

# ------------------------------------------------------------------------------
# Run it
# ------------------------------------------------------------------------------
# A missing or non-executable checkout is not a bad deployment. Rolling the OS
# back would not restore /var/media-stack, and would cost a reboot to prove it.
if [ ! -x "$CHECK" ]; then
	echo "greenboot/media-stack: $CHECK is not executable - nothing checked" >&2
	record missing
	exit 0
fi

# Output is left to stream rather than captured: verify-host.sh --greenboot is
# silent on success and prints its FAILs to stderr, and greenboot puts both into
# the journal, which is where the reason for a rollback needs to be.
timeout "$LIMIT" "$CHECK" --greenboot
rc=$?

case "$rc" in
	0)
		record green
		exit 0
		;;
	124)
		# INCONCLUSIVE, NOT RED. rpm-ostreed can block for tens of seconds
		# while it stages, and a slow boot must not be able to revert the OS.
		echo "greenboot/media-stack: verify-host.sh exceeded ${LIMIT}s - inconclusive" >&2
		record timeout
		exit 0
		;;
	*)
		record red
		exit "$rc"
		;;
esac
