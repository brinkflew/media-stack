#!/usr/bin/env bash
# ==============================================================================
# Record that greenboot judged this boot unhealthy
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as root, from greenboot when the verdict is red.
# Symlinked into /etc/greenboot/red.d/ - see host/greenboot/README.md.
#
# THIS EXISTS TO BREAK A LOOP, not to report. FCOS's own documentation names the
# trap: after a deployment is rolled back, nothing has told the updater that the
# image was bad, so it stages the same digest again within the day. Pair that
# with an unattended reboot window and the host reverts and re-applies a broken
# deployment every night, for ever, healing nothing and telling no one.
#
# So a red boot leaves a mark that does not age out. bin/reboot-when-staged.sh
# refuses to reboot while it is present, and bin/verify-host.sh raises it in the
# MOTD. Clearing it is a human act, deliberately: the question it asks is "do you
# know why this deployment was rejected", and only a person can answer that.
#
#   sudo /var/home-server/bin/clear-red-boot.sh
#
# THAT IS A SCRIPT RATHER THAN A `sed`, AND THE REASON COST AN OS UPDATE. A red
# boot arms TWO things, and this file writes only one of them:
#
#   red_boot_at    ours, below. It holds bin/reboot-when-staged.sh.
#   boot_counter   GRUB's, in /boot/grub2/grubenv, armed by greenboot. It is
#                  what actually DECIDES what boots - /boot/grub2/custom.cfg
#                  takes `set default=1`, the previous deployment, while it is
#                  set and boot_success is 0.
#
# The old recipe here was `sed -i '/^red_boot_at=/d'`, which cleared our refusal
# and left GRUB pointed at the fallback. Only a GREEN boot clears boot_counter,
# so on 2026-08-18 a deliberate, attended reboot - two days after the red boot,
# after the cause was fixed and the marker cleared - was silently converted into
# a rollback. The staged deployment finalized at shutdown, wrote its 146 MB
# /boot entry, and was never booted. bin/verify-host.sh now reports the second
# arm as greenboot.boot_target; clear-red-boot.sh clears both together.
#
# It writes red_boot_at rather than rollback_at because red is what actually
# happened. A rollback follows only once the boot counter is exhausted -
# GREENBOOT_MAX_BOOT_ATTEMPTS boots later - so naming the key after the rollback
# would claim something that may not have happened yet.
# ==============================================================================

set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/usr/sbin:/usr/local/sbin"

STATE="${HOME_SERVER_BOOT_STATE:-/var/lib/home-server/boot-state}"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$STATE")"

# Merge rather than overwrite. The check wrapper has already written this boot's
# verdict into the same file, and it runs first - greenboot runs every check
# before it runs red.d - so dropping what is there would discard the reason.
#
# The FIRST red boot is the one worth keeping. If this is a rollback loop, later
# boots are consequences, and overwriting the timestamp each time would make a
# problem that started on Tuesday look like it started this morning.
{
	grep -v '^red_boot_at=' "$STATE" 2>/dev/null
	if grep -q '^red_boot_at=' "$STATE" 2>/dev/null; then
		grep '^red_boot_at=' "$STATE"
	else
		echo "red_boot_at=$now"
	fi
} >"$STATE.tmp"
mv "$STATE.tmp" "$STATE"

echo "greenboot/home-server: recorded a RED boot in $STATE - unattended reboots are held" >&2
