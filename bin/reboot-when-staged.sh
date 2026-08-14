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
# IT IS ALL REFUSALS, WITH ONE NAMED EXCEPTION. Every check here is a reason NOT
# to reboot, and the default is to do nothing - because nobody is watching, the
# machine has no console, and a morning where it declines to reboot costs nothing
# while a morning where it should not have costs a car journey.
# bin/reboot-host.sh is the attended equivalent and is deliberately more
# permissive: a person is reading its output and can decide, so it warns where
# this refuses.
#
# THE EXCEPTION IS THE ENCODER, PAST A THRESHOLD, and it is there because a gate
# that is correct every time can still be wrong in aggregate. The window is five
# attempts on one Sunday morning; a Tdarr queue spanning all five costs the
# deployment a week, and a queue that does so repeatedly costs it indefinitely.
# Past 14 days staged or 30 days of uptime the script kills the transcode and
# applies, because at that point one hour of GPU time is cheaper than another
# month on a superseded image. Every other gate here refuses without limit.
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
# MEDIA_STACK_STATUS_JSON exists so the refusals below can be exercised without
# waiting for a real deployment to stage. This script is nothing BUT refusals,
# and every gate past the first is unreachable on a host with nothing staged -
# which is most nights. An untestable refusal is the same shape as a check that
# cannot fail, and this repository has found enough of those.
if [ -n "${MEDIA_STACK_STATUS_JSON:-}" ]; then
	status_json=$(cat "$MEDIA_STACK_STATUS_JSON" 2>/dev/null)
else
	status_json=$(rpm-ostree status --json 2>/dev/null)
fi
[ -n "$status_json" ] || refuse "rpm-ostree status returned nothing"

staged=$(jq -r '.deployments[] | select(.staged) | .version // empty' <<<"$status_json")
[ -n "$staged" ] || refuse "nothing is staged"

depl_count=$(jq '.deployments | length' <<<"$status_json")

# HOW LONG THIS ONE HAS BEEN WAITING, which is what decides below whether a
# transcode still outranks an OS update. /run/ostree/staged-deployment is the
# same source bin/verify-host.sh uses for its MOTD line, and it is honest here
# because a staged deployment cannot outlive a reboot: ostree-finalize-staged
# applies it at shutdown, so the file's mtime really is "since we last declined".
#
# The override exists for the same reason MEDIA_STACK_STATUS_JSON does, and the
# reason is stronger: the escalation below is unreachable for a fortnight, and a
# branch nobody can reach is the same shape as one that cannot fire.
if [ -n "${MEDIA_STACK_STAGED_AGE_DAYS:-}" ]; then
	staged_age_d="$MEDIA_STACK_STAGED_AGE_DAYS"
elif [ -e /run/ostree/staged-deployment ]; then
	staged_age_d=$(( ( $(date +%s) - $(stat -c %Y /run/ostree/staged-deployment) ) / 86400 ))
else
	staged_age_d=0
fi
uptime_d=$(( $(cut -d. -f1 /proc/uptime) / 86400 ))
note "staged $staged (${staged_age_d}d ago), $depl_count deployment(s) on disk, up ${uptime_d}d"

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

# THE BACKUP GATE BELONGS HERE, NOT IN THE UNIT. media-stack-reboot.service
# carries After=media-stack-backup.service and that does NOT do what it looks
# like: systemd ordering applies to units in the same job transaction, and a
# backup already running at 05:08 was started by its own timer hours earlier, so
# it is not in this transaction and nothing waits for it. Rebooting through
# restic leaves a partial snapshot and a lock in the off-site repository.
#
# The schedule makes this unlikely rather than impossible - 03:00 plus a 45
# minute timeout against a window that opens at 05:00 - which is exactly the
# kind of margin that quietly disappears when someone widens a timeout.
if [ "$(systemctl --user is-active media-stack-backup.service 2>/dev/null)" = active ]; then
	refuse "the backup is still running - rebooting through restic leaves a partial snapshot and an off-site lock"
fi

# ------------------------------------------------------------------------------
# Is anything mid-flight that a reboot would destroy?
# ------------------------------------------------------------------------------
# A killed transcode is not fatal - the source is hardlinked in downloads/ and
# untouched, and Tdarr re-queues the job - but it wastes an hour of GPU time and
# leaves a partial file in the cache, and this reboot can simply happen an hour
# later instead. Attended, this is a warning; unattended, it is a refusal.
#
# UNKNOWN IS NOT IDLE. Summing an empty answer through awk yields 0, so a driver
# that has stopped answering used to pass this gate looking exactly like an idle
# card - a check that cannot fail, on the one question it exists to ask.
# verify-host.sh --greenboot has already asserted the driver and the CDI spec by
# the time we get here, so an empty answer is anomalous rather than routine.
enc_raw=$(nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader,nounits 2>/dev/null)
[ -n "$enc_raw" ] || refuse "nvidia-smi answered nothing - cannot tell whether a transcode is running, and unknown is not idle"
enc=$(awk '{s+=$1} END {print s+0}' <<<"$enc_raw")

# THE ESCALATION, AND WHY IT IS NOT A CONTRADICTION. Each individual refusal
# above is correct and the aggregate can still be wrong: the window is five
# attempts on one morning, and a Tdarr queue that spans them costs the
# deployment a whole week. Repeat that and a correct-every-time gate leaves the
# host on a superseded image indefinitely.
#
# So the trade is named rather than implied. A killed transcode is a COST - one
# hour of GPU time against a source that still exists - while running an
# unapplied security update for a month is a RISK. Past the thresholds the cost
# is the cheaper of the two and the encoder stops being a veto.
#
# Two clauses, because they fail differently:
#
#   staged_age_d  how long THIS deployment has waited. Resets when a new image
#                 supersedes it, which is right - the new one gets its own
#                 chances - but on a stream that publishes weekly it would then
#                 never reach 14 and could never fire.
#   uptime_d      the backstop for exactly that. Nothing resets it except the
#                 reboot this script exists to perform, so it cannot be starved.
ESCALATE_STAGED_D=14
ESCALATE_UPTIME_D=30
if [ "$enc" -ne 0 ]; then
	if [ "$staged_age_d" -ge "$ESCALATE_STAGED_D" ] || [ "$uptime_d" -ge "$ESCALATE_UPTIME_D" ]; then
		note "the encoder is busy (${enc}%) but this deployment has waited ${staged_age_d}d and the host has been up ${uptime_d}d - applying anyway. A transcode will be killed; Tdarr re-queues it and the source is hardlinked."
	else
		refuse "the encoder is busy (${enc}%) - a transcode would be killed (waited ${staged_age_d}d of ${ESCALATE_STAGED_D}, up ${uptime_d}d of ${ESCALATE_UPTIME_D}; past either it applies anyway)"
	fi
fi

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
