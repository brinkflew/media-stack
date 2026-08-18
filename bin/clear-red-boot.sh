#!/usr/bin/env bash
# ==============================================================================
# Acknowledge a rejected boot - BOTH arms of it
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as root. This is the human act that says "I know why that
# deployment was rejected", and it exists because saying so used to disarm only
# half of the machine.
#
#   sudo bin/clear-red-boot.sh             clear both markers
#   sudo bin/clear-red-boot.sh --dry-run   say what it would clear, change nothing
#
# A RED BOOT ARMS TWO SEPARATE THINGS, AND ONLY ONE OF THEM WAS EVER DOCUMENTED:
#
#   red_boot_at    OURS, in /var/lib/home-server/boot-state. Written by
#                  host/greenboot/50-record-red-boot.sh. It holds
#                  bin/reboot-when-staged.sh, and it is what verify-host.sh
#                  reports as greenboot.red_boot.
#   boot_counter   GRUB'S, in /boot/grub2/grubenv. It is what actually DECIDES
#                  what boots: /boot/grub2/custom.cfg takes `set default=1` -
#                  the previous deployment - whenever boot_counter is present
#                  and boot_success is 0, and boot_success is set to 1 only by a
#                  green greenboot run.
#
# So the old recipe - `sed -i '/^red_boot_at=/d' boot-state` - cleared our
# refusal and left the machine still pointed at the fallback. On 2026-08-18 that
# cost an OS update: the red boot was from the 16th, the cause was repaired, the
# marker was cleared by hand, every check passed, and the deliberate reboot two
# days later was silently converted into a rollback. The staged deployment was
# finalized at shutdown, wrote its 146 MB /boot entry, and was never booted -
# which also filled /boot, because a partition that holds two kernels was then
# holding the booted one and one nobody had asked for.
#
# boot_success IS DELIBERATELY NOT TOUCHED. Clearing boot_counter alone disarms
# the fallback - custom.cfg needs both - and that flag is greenboot's to manage:
# it sets it to 1 after a green run and custom.cfg resets it to 0 at every boot.
# Writing it here would be this script guessing at a verdict it has not earned.
#
# It does NOT decide anything. It is still a person answering a question, and it
# still refuses to run when there is nothing to acknowledge, so it cannot be put
# on a timer and quietly turned into "always reboot into the new thing".
# ==============================================================================

set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/usr/sbin:/usr/local/sbin"

STATE="${HOME_SERVER_BOOT_STATE:-/var/lib/home-server/boot-state}"
GRUBENV="${HOME_SERVER_GRUBENV:-/boot/grub2/grubenv}"
BOOTDIR="${HOME_SERVER_BOOT_DIR:-/boot}"

DRY=""
case "${1:-}" in
	"")        ;;
	--dry-run) DRY=1 ;;
	*)         echo "clear-red-boot: unknown argument: $1" >&2; exit 2 ;;
esac

if [ "$(id -u)" != 0 ]; then
	echo "clear-red-boot: must run as root - /boot is mounted ro and grubenv is 0600" >&2
	exit 2
fi

red=$(sed -n 's/^red_boot_at=//p' "$STATE" 2>/dev/null | tail -1)
counter=$(grub2-editenv "$GRUBENV" list 2>/dev/null | sed -n 's/^boot_counter=//p' | tail -1)

# NOTHING TO DO IS AN ANSWER, not a success. Reporting "cleared" when there was
# nothing armed would teach someone that running this is how you make a red boot
# go away, which is the opposite of the point.
if [ -z "$red" ] && [ -z "$counter" ]; then
	echo "clear-red-boot: nothing is armed - no red_boot_at in $STATE, no boot_counter in $GRUBENV"
	exit 0
fi

echo "clear-red-boot: found${red:+ red_boot_at=$red}${counter:+ boot_counter=$counter}"
if [ -n "$DRY" ]; then
	echo "clear-red-boot: dry run - nothing was changed"
	exit 0
fi

# ------------------------------------------------------------------------------
# Ours
# ------------------------------------------------------------------------------
# Write to a temporary and move, so a reader never sees a half-written file -
# the same shape 50-record-red-boot.sh and the backup state file use.
if [ -n "$red" ]; then
	grep -v '^red_boot_at=' "$STATE" >"$STATE.tmp" 2>/dev/null
	mv "$STATE.tmp" "$STATE"
	echo "clear-red-boot: cleared red_boot_at from $STATE"
fi

# ------------------------------------------------------------------------------
# GRUB's
# ------------------------------------------------------------------------------
# RESTORE WHAT WAS FOUND, rather than assuming ro. /boot is ro here and greenboot
# does the same dance around its own writes - but a host that mounts it rw must
# not be silently switched to ro by an unrelated command, so the original state
# is read first and put back either way.
if [ -n "$counter" ]; then
	was_ro=""
	findmnt -no OPTIONS "$BOOTDIR" 2>/dev/null | grep -qE '(^|,)ro(,|$)' && was_ro=1
	if [ -n "$was_ro" ]; then
		mount -o remount,rw "$BOOTDIR" || {
			echo "clear-red-boot: could not remount $BOOTDIR rw - boot_counter is STILL SET" >&2
			exit 1
		}
	fi
	rc=0
	grub2-editenv "$GRUBENV" unset boot_counter 2>/dev/null || rc=$?
	# Put the mount back BEFORE judging the result, so a failed edit does not
	# also leave /boot writable for the rest of the boot.
	[ -n "$was_ro" ] && mount -o remount,ro "$BOOTDIR"
	if [ "$rc" != 0 ]; then
		echo "clear-red-boot: grub2-editenv failed - boot_counter is STILL SET" >&2
		exit 1
	fi
	echo "clear-red-boot: cleared boot_counter from $GRUBENV - the next boot selects the default deployment"
fi

echo "clear-red-boot: done. Confirm with: bin/verify-host.sh --json | jq '.checks[]|select(.id==\"greenboot.boot_target\")'"
