#!/usr/bin/env bash
# ==============================================================================
# Apply a staged deployment, unattended, but only when it is safe to
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as `core`, from media-stack-reboot.timer. This is the other
# half of greenboot: greenboot decides whether a deployment was good AFTER the
# reboot, and this decides whether to reboot at all.
#
#   bin/reboot-when-staged.sh --dry-run   say what it would do, change nothing
#   bin/reboot-when-staged.sh             reboot, if every gate below passes
#
# IT IS ALL REFUSALS. Every check here is a reason NOT to reboot, and the default
# is to do nothing - because nobody is watching, the machine has no console, and
# a night where it declines to reboot costs nothing while a night where it should
# not have costs a car journey. bin/reboot-host.sh is the attended equivalent and
# is deliberately more permissive: a person is reading its output and can
# decide, so it warns where this refuses.
#
# THE ONE GATE THAT IS NOT ABOUT THIS REBOOT is the red_boot_at marker. FCOS's
# own documentation names the trap: nothing tells the updater that an image was
# bad, so it re-stages the same digest within the day. Without this gate, an
# armed greenboot plus this timer is a host that reverts and re-applies a broken
# deployment every single night, healing nothing and telling nobody. The marker
# is written by the red.d hook and cleared by a person, which is the point - the
# question it asks is "do you know why that deployment was rejected".
# ==============================================================================

set -uo pipefail

export PATH="${HOME:-/var/home/core}/.local/bin:$PATH"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${MEDIA_STACK_BOOT_STATE:-/var/lib/media-stack/boot-state}"
BOOT_MIN_MB=160

DRY=""
case "${1:-}" in
	"")        ;;
	--dry-run) DRY=1 ;;
	*)         echo "reboot-when-staged: unknown argument: $1" >&2; exit 2 ;;
esac

if [ "$(id -u)" = 0 ]; then priv() { "$@"; }; else priv() { sudo -n "$@"; }; fi

refuse() { printf 'reboot-when-staged: NOT rebooting - %s\n' "$1"; exit 0; }
note()   { printf 'reboot-when-staged: %s\n' "$1"; }

# ------------------------------------------------------------------------------
# Is there anything to apply?
# ------------------------------------------------------------------------------
# Exit 0 rather than 1: "nothing staged" is the normal state on most nights and
# a timer that goes red on a quiet week is a timer people stop reading.
status_json=$(rpm-ostree status --json 2>/dev/null)
[ -n "$status_json" ] || refuse "rpm-ostree status returned nothing"

staged=$(jq -r '.deployments[] | select(.staged) | .version // empty' <<<"$status_json")
[ -n "$staged" ] || refuse "nothing is staged"

depl_count=$(jq '.deployments | length' <<<"$status_json")
note "staged $staged, $depl_count deployment(s) on disk"

# ------------------------------------------------------------------------------
# Would greenboot be able to undo this?
# ------------------------------------------------------------------------------
# Rebooting into a new deployment with no safety net is exactly the attended
# procedure, and this is not attended. Both halves have to be there: the check in
# required.d, and the GRUB counter - either alone is inert, silently.
[ -x /usr/libexec/greenboot/greenboot ] || refuse "greenboot is not installed - a bad deployment could not roll itself back"
[ -e /etc/greenboot/check/required.d/40-media-stack.sh ] || refuse "the health check is not in required.d - greenboot would only log"
[ -f /boot/grub2/custom.cfg ] || refuse "no GRUB boot counter - greenboot could not roll back"
[ "$depl_count" -ge 2 ] || refuse "only $depl_count deployment - there would be nothing to roll back to"

# ------------------------------------------------------------------------------
# Did the last attempt end badly?
# ------------------------------------------------------------------------------
red=$(sed -n 's/^red_boot_at=//p' "$STATE" 2>/dev/null | tail -1)
[ -z "$red" ] || refuse "a deployment was rejected at $red and nobody has cleared it.
  Understand why, then:  sudo sed -i '/^red_boot_at=/d' $STATE"

# ------------------------------------------------------------------------------
# Is the host healthy RIGHT NOW?
# ------------------------------------------------------------------------------
# The same argument bin/reboot-host.sh makes: rebooting an unhealthy host turns
# one problem into two and leaves nobody able to say which caused which. Only the
# host-level battery, for the same reason greenboot uses it - a slow Tdarr start
# is not a reason to postpone an OS update for ever.
"$REPO/bin/verify-host.sh" --greenboot >/dev/null 2>&1 \
	|| refuse "verify-host.sh --greenboot fails now - fix that before applying a new deployment"

boot_free=$(df -Pm /boot | awk 'NR==2 {print $4}')
[ "$boot_free" -ge "$BOOT_MIN_MB" ] \
	|| refuse "/boot has only ${boot_free}M free (want ${BOOT_MIN_MB}M)"

pinned=$(jq '[.deployments[] | select(.pinned)] | length' <<<"$status_json")
[ "$pinned" -eq 0 ] || refuse "$pinned deployment(s) pinned - unpin and 'rpm-ostree cleanup -r' first"

# ------------------------------------------------------------------------------
# Is anything mid-flight that a reboot would destroy?
# ------------------------------------------------------------------------------
# A killed transcode is not fatal - the source is untouched and Tdarr redoes the
# job - but it wastes an hour of GPU time and leaves a partial file in the cache,
# and this reboot can simply happen next week instead. Attended, this is a
# warning; unattended, it is a refusal.
enc=$(nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader,nounits 2>/dev/null \
	| awk '{s+=$1} END {print s+0}')
[ "${enc:-0}" -eq 0 ] || refuse "the encoder is busy (${enc}%) - a transcode would be killed"

# ------------------------------------------------------------------------------
# Go
# ------------------------------------------------------------------------------
if [ -n "$DRY" ]; then
	note "every gate passed - a real run would reboot into $staged now"
	exit 0
fi

# Record the attempt BEFORE rebooting, because afterwards there is no process
# left to write anything. Without this, "the timer applied an update at 05:00"
# and "the timer has not fired since March" look identical from the far side.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
priv mkdir -p "$(dirname "$STATE")"
{
	grep -v '^unattended_reboot_at=' "$STATE" 2>/dev/null
	echo "unattended_reboot_at=$now"
} | priv tee "$STATE.tmp" >/dev/null
priv mv "$STATE.tmp" "$STATE"

note "rebooting into $staged"
priv systemctl reboot
