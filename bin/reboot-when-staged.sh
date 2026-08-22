#!/usr/bin/env bash
# ==============================================================================
# Apply a staged deployment, unattended, but only when it is safe to
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as `core`, from home-server-reboot.timer. This is the other
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
# THE NAMED EXCEPTIONS ARE THE THREE MID-FLIGHT GATES, and they exist because a
# gate that is correct every time can still be wrong in aggregate. The window is
# five attempts on one Sunday morning; a Tdarr queue spanning all five costs the
# deployment a week, and a queue that does so repeatedly costs it indefinitely.
#
#   the encoder   past 14 days staged or 30 days of uptime the script kills the
#                 transcode and applies, because at that point one hour of GPU
#                 time is cheaper than another month on a superseded image.
#   a phase       gives way after the second refusal of a morning - a killed
#                 phase costs one re-run against a worktree still on disk.
#   playback      gives way after the second refusal of a morning - a dropped
#                 stream costs about fifteen seconds and Jellyfin has already
#                 saved the position.
#
# The two cheap ones are counted per morning and the expensive one is measured
# in days, which is the whole of how the three are priced apart. Every other
# gate here refuses without limit.
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
STATE="${HOME_SERVER_BOOT_STATE:-/var/lib/home-server/boot-state}"
GRUBENV="${HOME_SERVER_GRUBENV:-/boot/grub2/grubenv}"
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
# HOME_SERVER_STATUS_JSON exists so the refusals below can be exercised without
# waiting for a real deployment to stage. This script is nothing BUT refusals,
# and every gate past the first is unreachable on a host with nothing staged -
# which is most nights. An untestable refusal is the same shape as a check that
# cannot fail, and this repository has found enough of those.
if [ -n "${HOME_SERVER_STATUS_JSON:-}" ]; then
	status_json=$(cat "$HOME_SERVER_STATUS_JSON" 2>/dev/null)
else
	status_json=$(rpm-ostree status --json 2>/dev/null)
fi
[ -n "$status_json" ] || refuse "rpm-ostree status returned nothing"

# INDEX 0 IS WHAT BOOTS NEXT, AND `select(.staged)` IS NOT - see the long note at
# next_dep in bin/verify-host.sh. Written the obvious way this gate was blind to
# a FINALIZED pending deployment (.staged=false, /boot entry already written),
# and refused "nothing is staged" about a deployment sitting ready at index 0.
# That is not a missed opportunity, it is a permanent one: nothing else applies
# it, so the deployment stays unbooted and its /boot slot stays spent, every
# Sunday, for ever, with no human in the loop. Found on 2026-08-18.
staged=$(jq -r '.deployments[0] | select(.booted | not) | .version // empty' <<<"$status_json")
[ -n "$staged" ] || refuse "nothing is waiting to boot"

# WOULD THIS REBOOT APPLY IT, OR ROLL BACK? custom.cfg selects the PREVIOUS
# deployment whenever boot_counter is set and boot_success is 0, and boot_success
# is set to 1 only by a green greenboot run - so a red boot leaves GRUB armed
# until the machine boots green once. Rebooting into that unattended does the
# exact damage this whole script exists to prevent: it rolls back silently, and
# the deployment it declined to boot stays finalized and unbooted, holding a
# /boot slot on a partition that has two. Exactly what happened on 2026-08-18,
# attended, where at least someone was reading the output.
#
# This does NOT deadlock, which is the trap this repo has hit three times: the
# marker is clearable without a reboot, and the refusal names how.
grub_counter=$(priv grub2-editenv "$GRUBENV" list 2>/dev/null | sed -n 's/^boot_counter=//p' | tail -1)
[ -z "$grub_counter" ] || refuse "GRUB is armed to boot the FALLBACK (boot_counter=$grub_counter);
  this reboot would roll back rather than apply $staged.
  Understand why, then:  sudo $REPO/bin/clear-red-boot.sh"

depl_count=$(jq '.deployments | length' <<<"$status_json")

# HOW LONG THIS ONE HAS BEEN WAITING, which is what decides below whether a
# transcode still outranks an OS update. /run/ostree/staged-deployment is the
# same source bin/verify-host.sh uses for its MOTD line.
#
# THIS COMMENT USED TO SAY "a staged deployment cannot outlive a reboot", AND
# THAT IS FALSE. ostree-finalize-staged FINALIZES it at shutdown; it does not
# make GRUB boot it. If GRUB takes the fallback, the deployment outlives the
# reboot as a pending one - finalized, entered in /boot, unbooted - and
# /run/ostree/staged-deployment is gone, because staging really did end. So the
# `else 0` below reported a fortnight-old deployment as brand new, which is the
# direction that silently disables the escalation: the transcode gate would
# outrank it for ever. Fall back to the boot entry's own mtime, which is written
# at finalization and is exactly "since this became ready to boot".
#
# The override exists for the same reason HOME_SERVER_STATUS_JSON does, and the
# reason is stronger: the escalation below is unreachable for a fortnight, and a
# branch nobody can reach is the same shape as one that cannot fire.
if [ -n "${HOME_SERVER_STAGED_AGE_DAYS:-}" ]; then
	staged_age_d="$HOME_SERVER_STAGED_AGE_DAYS"
elif [ -e /run/ostree/staged-deployment ]; then
	staged_age_d=$(( ( $(date +%s) - $(stat -c %Y /run/ostree/staged-deployment) ) / 86400 ))
else
	# Newest boot entry, which for a pending deployment is its own. `stat` on a
	# glob that matches nothing yields no output, so the arithmetic is guarded
	# rather than assumed - `set -u` is on and this runs unattended.
	newest=$(priv stat -c %Y /boot/ostree/*/ 2>/dev/null | sort -n | tail -1)
	if [ -n "${newest:-}" ]; then
		staged_age_d=$(( ( $(date +%s) - newest ) / 86400 ))
	else
		staged_age_d=0
	fi
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
[ -e /etc/greenboot/check/required.d/40-home-server.sh ] || refuse "the health check is not in required.d - greenboot would only log"
[ -f /boot/grub2/custom.cfg ] || refuse "no GRUB boot counter - greenboot could not roll back"
[ "$depl_count" -ge 2 ] || refuse "only $depl_count deployment - there would be nothing to roll back to"

# ------------------------------------------------------------------------------
# Did the last attempt end badly?
# ------------------------------------------------------------------------------
# WHICH deployment was rejected, not merely that one was. Refusing on the
# timestamp alone was right for the image that failed and wrong for its fix: once
# ublue publishes a corrected image nothing could tell the two apart, so this
# gate went on declining every Sunday until a human cleared the marker by hand -
# the "host silently stops taking OS security updates" failure from a third
# direction. It held from 11:55 on 2026-08-18 and was cleared manually.
#
# A MARKER WITH NO CHECKSUM STILL BLOCKS EVERYTHING. Markers written before this
# change carry no identity, and treating "no checksum" as "no match" would
# quietly un-hold every one of them - turning a safety change into a silent
# release of exactly the brake it is about. Absent means block, which is also
# what happens when the wrapper could not read the checksum at all.
red=$(sed -n 's/^red_boot_at=//p' "$STATE" 2>/dev/null | tail -1)
red_csum=$(sed -n 's/^red_boot_csum=//p' "$STATE" 2>/dev/null | tail -1)
if [ -n "$red" ]; then
	next_csum=$(jq -r '.deployments[0].checksum // empty' <<<"$status_json")
	if [ -z "$red_csum" ]; then
		refuse "a deployment was rejected at $red and nobody has cleared it.
  Understand why, then:  sudo $REPO/bin/clear-red-boot.sh"
	elif [ "$red_csum" = "$next_csum" ]; then
		refuse "this is the SAME deployment greenboot rejected at $red (${red_csum:0:12}).
  Rebooting would repeat it. Understand why, then:  sudo $REPO/bin/clear-red-boot.sh"
	else
		note "a deployment was rejected at $red (${red_csum:0:12}), but ${next_csum:0:12} is a different one - proceeding"
	fi
fi

# ------------------------------------------------------------------------------
# Is the host healthy RIGHT NOW?
# ------------------------------------------------------------------------------
# The same argument bin/reboot-host.sh makes: rebooting an unhealthy host turns
# one problem into two and leaves nobody able to say which caused which. Only the
# host-level battery, for the same reason greenboot uses it - a slow Tdarr start
# is not a reason to postpone an OS update for ever.
"$REPO/bin/verify-host.sh" --greenboot >/dev/null 2>&1 \
	|| refuse "verify-host.sh --greenboot fails now - fix that before applying a new deployment"

# THE SLOT IS ONLY NEEDED IF A KERNEL HAS TO BE WRITTEN, and only a STAGED
# deployment writes one - ostree-finalize-staged does it at shutdown. A PENDING
# deployment already has its entry, so this reboot writes nothing.
#
# GATING BOTH ON FREE SPACE DEADLOCKS, and unattended that means for ever. A
# pending deployment is holding the second /boot slot, which is what puts /boot
# below the threshold; booting it is what turns it into a rollback that
# `rpm-ostree cleanup -r` can then free. So the refusal was blocking the only
# thing that resolves its own condition - the same shape as host.failed_units
# counting greenboot-healthcheck.service, and as greenboot.verdict before it.
# Verified against the live host on 2026-08-18, where this refused at 26M free
# with a pending deployment and would have gone on refusing every Sunday.
boot_free=$(df -Pm /boot | awk 'NR==2 {print $4}')
next_staged=$(jq -r '.deployments[0] | select(.booted | not) | select(.staged) | .version // empty' <<<"$status_json")
if [ "$boot_free" -lt "$BOOT_MIN_MB" ] && [ -n "$next_staged" ]; then
	refuse "/boot has only ${boot_free}M free (want ${BOOT_MIN_MB}M) and $next_staged is STAGED - finalizing it needs a slot"
fi

pinned=$(jq '[.deployments[] | select(.pinned)] | length' <<<"$status_json")
[ "$pinned" -eq 0 ] || refuse "$pinned deployment(s) pinned - unpin and 'rpm-ostree cleanup -r' first"

# THE BACKUP GATE BELONGS HERE, NOT IN THE UNIT. home-server-reboot.service
# carries After=home-server-backup.service and that does NOT do what it looks
# like: systemd ordering applies to units in the same job transaction, and a
# backup already running at 05:08 was started by its own timer hours earlier, so
# it is not in this transaction and nothing waits for it. Rebooting through
# restic leaves a partial snapshot and a lock in the off-site repository.
#
# The schedule makes this unlikely rather than impossible - 03:00 plus a 45
# minute timeout against a window that opens at 05:00 - which is exactly the
# kind of margin that quietly disappears when someone widens a timeout.
# AND `is-active` IS THE WRONG QUESTION FOR A ONESHOT. home-server-backup is
# Type=oneshot with RemainAfterExit=no, so for the entire time restic is running
# its ActiveState is `activating` - never `active`. Written the obvious way,
# `[ "$(systemctl --user is-active ...)" = active ]`, this gate could not fire at
# any point in the unit's life. It read correctly, it deployed cleanly, and it
# was dead. Found only by starting a real backup and watching it pass.
#
# So the safe states are allowlisted rather than the busy ones denylisted: a
# state this does not recognise is treated as busy, which is the direction that
# fails safe. RemainAfterExit=no is what makes `inactive` mean finished rather
# than never-started, and is worth re-checking if that unit is ever changed.
backup_state=$(systemctl --user show home-server-backup.service -p ActiveState --value 2>/dev/null)
case "$backup_state" in
	inactive|failed|"") ;;
	*) refuse "the backup is $backup_state - rebooting through restic leaves a partial snapshot and a lock in the off-site repository" ;;
esac

# A PHASE IS MID-FLIGHT, AND ONLY A MARKER CAN SAY SO. conduct is a long-running
# unit, so its ActiveState reads `active` from boot to shutdown whether it is
# driving a phase or sitting idle - the exact mirror of the backup gate above,
# where a oneshot is `activating` for its entire working life and never `active`.
# Both are the obvious question, both read correctly, and both are dead. So this
# reads a marker the process writes about itself.
#
# BUSY ONLY WHEN THE MARKER SAYS BUSY *AND* ITS HEARTBEAT IS FRESH. A conduct
# killed mid-phase leaves phase_in_flight=1 behind for ever, and a stale flag
# that vetoes reboots indefinitely is the "host silently stops taking OS security
# updates" failure arriving from a fourth direction. Fresh is 600s, which is the
# same window agents.conduct_fresh grades.
conduct_state="${HOME_SERVER_CONDUCT_STATE:-${HOME:-/var/home/core}/.cache/home-server/conduct-state}"
phase_flag=$(sed -n 's/^phase_in_flight=//p' "$conduct_state" 2>/dev/null | tail -1)
phase_hb=$(sed -n 's/^heartbeat_at=//p' "$conduct_state" 2>/dev/null | tail -1)
phase_hb_age=""
if [ -n "$phase_hb" ]; then
	hb_epoch=$(date -d "$phase_hb" +%s 2>/dev/null)
	[ -z "${hb_epoch:-}" ] || phase_hb_age=$(( $(date +%s) - hb_epoch ))
fi
if [ "${phase_flag:-0}" = 1 ] && [ -n "$phase_hb_age" ] && [ "$phase_hb_age" -le 600 ]; then
	# THE ESCALATION IS EASIER THAN THE ENCODER'S BELOW, and naming the trade is
	# what makes it defensible rather than arbitrary. A killed phase costs one
	# re-run of minutes against a worktree that is still on disk; a killed
	# transcode costs an hour of GPU time. So this gives way after the second
	# refusal of a morning where the encoder holds out for a fortnight.
	#
	# IT ALSO MAKES A REQUIREMENT NON-NEGOTIABLE RATHER THAN ASPIRATIONAL:
	# conduct must survive being killed mid-phase, with durable state and a
	# boot-time pass that reclaims leases and reaps orphaned worktrees,
	# containers and networks. A design note saying so would be a wish. This
	# guarantees it gets exercised, on a schedule, without anybody deciding to.
	#
	# Date-keyed so it resets between windows. The counter cannot be starved the
	# way the encoder's staged_age_d can, because the day advances regardless of
	# what conduct is doing.
	today=$(date -u +%Y-%m-%d)
	prev_day=$(sed -n 's/^phase_refused_on=//p' "$STATE" 2>/dev/null | tail -1)
	prev_n=$(sed -n 's/^phase_refusals=//p' "$STATE" 2>/dev/null | tail -1)
	case "$prev_n" in ''|*[!0-9]*) prev_n=0 ;; esac
	[ "$prev_day" = "$today" ] || prev_n=0
	if [ "$prev_n" -ge 2 ]; then
		note "a phase has been in flight at $prev_n earlier attempts this morning - applying anyway. The phase dies with the reboot; conduct's reconciler reclaims its lease and its worktree on the way back up, which is the property this escalation exists to keep honest."
	else
		# RECORDED BEFORE REFUSING, because refuse() exits immediately - and not
		# at all under --dry-run, which must change nothing. The block rewrites
		# the file whole and keeps every key it does not own, the same shape the
		# unattended_reboot_at write at the end of this script uses.
		if [ -z "$DRY" ]; then
			{
				grep -vE '^phase_refus(als|ed_on)=' "$STATE" 2>/dev/null
				echo "phase_refused_on=$today"
				echo "phase_refusals=$((prev_n + 1))"
			} | priv tee "$STATE.tmp" >/dev/null
			priv mv "$STATE.tmp" "$STATE"
		fi
		refuse "conduct has a phase in flight (heartbeat ${phase_hb_age}s ago) - a reboot would kill it mid-run.
  Refusal $((prev_n + 1)) of 2 this morning; the next attempt applies anyway."
	fi
fi

# ------------------------------------------------------------------------------
# Is anything mid-flight that a reboot would destroy?
# ------------------------------------------------------------------------------
# SOMEBODY IS WATCHING, AND THE ENCODER GATE BELOW CANNOT SEE THEM. That is not
# a shortcoming of nvidia-smi: a DirectPlay session hands the file to the client
# untouched and opens no encode session at all, so the only measurement this
# section used to have reads 0% while a film is playing. Measured on this host -
# a live DirectPlay session with utilization.encoder at 0. For as long as this
# section was one gate, the Sunday window could cut a stream with every check
# passing and nothing anywhere saying otherwise.
#
# UNKNOWN REFUSES HERE, and the same script proceeds on unknown in
# bin/update-when-idle.sh. The asymmetry is the one this whole file is built on
# and bin/reboot-host.sh restates: a container update costs an interrupted
# stream, a reboot costs a car journey, so they are allowed to price the same
# missing answer differently. Note that bin/jellyfin-watching.sh reports a
# STOPPED Jellyfin as 0 rather than unknown, so this cannot refuse merely
# because the media server is down.
watching=$("$REPO/bin/jellyfin-watching.sh") ||
	refuse "jellyfin is running and could not be asked whether anyone is watching - unknown is not idle"
if [ "${watching:-0}" -gt 0 ]; then
	# THE COUNT IDIOM, NOT THE ENCODER'S AGE IDIOM, and for the reason the phase
	# gate above gives: this costs what a killed phase costs, not what a killed
	# transcode costs. A viewer loses about fifteen seconds and resumes, because
	# Jellyfin saves the position - so it gives way after the second refusal of a
	# morning where the encoder holds out for a fortnight.
	#
	# Date-keyed so it resets between windows, and it cannot be starved: the day
	# advances regardless of what anyone is watching.
	today=$(date -u +%Y-%m-%d)
	prev_day=$(sed -n 's/^playback_refused_on=//p' "$STATE" 2>/dev/null | tail -1)
	prev_n=$(sed -n 's/^playback_refusals=//p' "$STATE" 2>/dev/null | tail -1)
	case "$prev_n" in ''|*[!0-9]*) prev_n=0 ;; esac
	[ "$prev_day" = "$today" ] || prev_n=0
	if [ "$prev_n" -ge 2 ]; then
		note "$watching session(s) playing, refused at $prev_n earlier attempts this morning - applying anyway. The stream drops; Jellyfin has the position saved and the client resumes on the way back up."
	else
		# Recorded BEFORE refusing, because refuse() exits immediately - and not
		# at all under --dry-run. Same shape as the phase counter above.
		if [ -z "$DRY" ]; then
			{
				grep -vE '^playback_refus(als|ed_on)=' "$STATE" 2>/dev/null
				echo "playback_refused_on=$today"
				echo "playback_refusals=$((prev_n + 1))"
			} | priv tee "$STATE.tmp" >/dev/null
			priv mv "$STATE.tmp" "$STATE"
		fi
		refuse "$watching Jellyfin session(s) are playing - a reboot would cut the stream.
  Refusal $((prev_n + 1)) of 2 this morning; the next attempt applies anyway."
	fi
fi

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
#
# The override is the same argument again, and it is not hypothetical: this
# branch was unprovable the first time it was tried, because the transcode that
# had been running while the code was written finished before the test ran. A
# gate that can only be exercised when something else happens to be busy is a
# gate nobody exercises.
enc_raw="${HOME_SERVER_ENCODER_PCT:-}"
if [ -z "$enc_raw" ]; then
	enc_raw=$(nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader,nounits 2>/dev/null)
	[ -n "$enc_raw" ] || refuse "nvidia-smi answered nothing - cannot tell whether a transcode is running, and unknown is not idle"
fi
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
