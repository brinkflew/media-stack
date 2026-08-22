#!/usr/bin/env bash
# ==============================================================================
# Let the nightly container update run, but not through someone's film
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as ExecCondition= on podman-auto-update.service. There is
# little reason to run it by hand except with --dry-run.
#
#   bin/update-when-idle.sh --dry-run   decide and explain, write no state
#   bin/update-when-idle.sh             decide, and record what was decided
#
# WHAT THIS EXISTS FOR. podman auto-update restarts a container whose image has
# moved, and Jellyfin follows :latest. On 2026-08-19 that happened at 00:20:30
# while somebody was mid-stream, and the series recorded the whole thing:
#
#   00:10-00:20  playing=1 total=3   steady
#   00:20:30     image pull, restart
#   00:21        (no sample at all - Jellyfin was down)
#   00:22        playing=0 total=0   everyone gone
#   00:23 on     playing=1 total=1   one client resumed; two never came back
#
# It is the only night in ten that Jellyfin's image actually moved, so the
# exposure is roughly weekly rather than nightly - which is exactly the shape
# that makes it worth gating rather than rescheduling. Moving the hour reduces
# the odds; it cannot remove them.
#
# IT GATES THE WHOLE RUN, NOT JELLYFIN. `podman auto-update` takes no filter -
# there is no --exclude and no per-unit selection - so the alternatives were to
# gate everything or to take Jellyfin out of auto-update altogether. The latter
# was rejected three times over: it turns Jellyfin's updates off permanently
# rather than conditionally, it gives up podman's rollback (which Notify=healthy
# in the quadlet exists to arm), and it trips update.policy_count in
# bin/verify-host.sh, which derives both sides of its count from the same
# authority and FAILs on a mismatch.
#
# Deferring all twenty-seven containers by an hour costs nothing. The run is an
# "eventually" job: nothing here needs an image on the night it is published,
# and host/systemd/podman-auto-update.timer.d gives the deferral two more slots
# the same night rather than making it wait a day.
#
# EXIT 1 IS A REFUSAL, WHICH IS THE ONE PLACE THIS DIVERGES FROM
# bin/reboot-when-staged.sh - there, refuse() exits 0 for exactly the same
# reason this one exits 1. ExecCondition= reads 1-254 as "skip this unit
# quietly" and leaves it NOT failed; 0 means go; 255 or a signal is a genuine
# failure. So a deferral is a skip in the journal rather than a red unit, which
# is the rule this repository already holds elsewhere: a rollout must not look
# like a fault, and a fault must not look like health.
#
# It runs BEFORE ExecStartPre=, so a deferred night also skips
# bin/pre-update-snapshot.sh. That is correct rather than a side effect: the
# snapshot exists to sit immediately in front of an update, and there is no
# update to sit in front of.
# ==============================================================================

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STATE="${HOME_SERVER_UPDATE_STATE:-$HOME/.cache/home-server/update-state}"

# THE CEILING, AND WHY IT IS THREE DAYS RATHER THAN THE ENCODER'S FOURTEEN.
# Same argument as bin/reboot-when-staged.sh's escalation - a gate that is
# correct on every individual refusal can still be wrong in aggregate - but the
# trade is priced differently, so the number is different.
#
# A killed transcode costs an hour of GPU time; that buys a fortnight of
# patience. An interrupted stream costs about fifteen seconds, and Jellyfin has
# already saved the position, so the client resumes where it was. The cheap
# interruption earns a cheap ceiling.
#
# IT IS ALSO THE ONLY THING THAT BREAKS THE CASE THE DATA ACTUALLY SHOWS. The
# staleness filter in bin/jellyfin-watching.sh drops clients that have gone
# away; it cannot drop a browser tab left open on a paused episode, which checks
# in perfectly all night. The series carries one unbroken run of 18.4 hours.
# Without a ceiling that run is a veto, and a household that does it habitually
# is a host that stops taking container updates while every signal reads green.
ESCALATE_DEFER_D="${HOME_SERVER_ESCALATE_DEFER_D:-3}"

# How long an allowed run suppresses the later attempts of the same window.
# host/systemd/podman-auto-update.timer.d fires at 00:00, 01:00 and 02:00, so
# without this a quiet night runs the whole update - and bin/pre-update-snapshot.sh's
# database dumps with it - three times instead of once. Six hours covers the
# window with room and is nowhere near the ~22h to the next one.
SETTLE_H="${HOME_SERVER_UPDATE_SETTLE_H:-6}"

DRY=""
case "${1:-}" in
	"")        ;;
	--dry-run) DRY=1 ;;
	*)         echo "update-when-idle: unknown argument: $1" >&2; exit 64 ;;
esac

now=$(date -u +%s)
now_iso=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)

note() { printf 'update-when-idle: %s\n' "$1"; }

# Read one key out of the flat key=value state file. Empty when absent, which is
# how "never" stays distinguishable from a real value everywhere below.
sget() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }

# Seconds since an ISO-8601 stamp, or empty if it is absent or unparseable. An
# unparseable stamp must not become 0 - that reads as "just now", which is the
# direction that silently disarms the ceiling.
age_s() {
	local at epoch
	at=$(sget "$1")
	[ -n "$at" ] || return 0
	epoch=$(date -u -d "$at" +%s 2>/dev/null) || return 0
	[ -n "$epoch" ] || return 0
	echo $(( now - epoch ))
}

# Rewrite the state file whole, preserving every key not named here. Its own
# file rather than a key in backup-state, deliberately: bin/backup-server.sh
# rewrites THAT file whole at 03:00 and every foreign key needs an explicit
# carry-forward line there, which is an obligation not worth inheriting for a
# marker written three hours earlier every night.
#
# A key given an EMPTY value is removed rather than stored blank, which is what
# lets allow() clear a streak with `deferring_since=` and keeps sget's "absent
# means never" reading true.
sset() {
	[ -z "$DRY" ] || return 0
	local pat
	pat=$(printf '%s\n' "$@" | sed 's/=.*//' | paste -sd'|' -)
	mkdir -p "$(dirname "$STATE")"
	{
		[ ! -f "$STATE" ] || grep -vE "^($pat)=" "$STATE"
		printf '%s\n' "$@"
	} 2>/dev/null | grep -vE '^$|=$' | sort >"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
}

# A refusal, which for an ExecCondition is exit 1. Records the streak so the
# ceiling above has something to measure and bin/verify-host.sh has something to
# report - without it a deferral is invisible the moment the journal rotates.
refuse() {
	local since n
	since=$(sget deferring_since)
	[ -n "$since" ] || since="$now_iso"
	n=$(sget defers)
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	sset "last_run_at=$now_iso" "last_defer_at=$now_iso" \
	     "deferring_since=$since" "defer_reason=$2" "defers=$(( n + 1 ))"
	printf 'update-when-idle: NOT updating - %s\n' "$1"
	exit 1
}

# Go. Clears the streak, because the thing the streak measures has just stopped
# being true.
allow() {
	note "$1"
	sset "last_run_at=$now_iso" "last_allowed_at=$now_iso" \
	     "deferring_since=" "defer_reason=" "defers=0"
	exit 0
}

# ------------------------------------------------------------------------------
# Has this window already run?
# ------------------------------------------------------------------------------
allowed_age=$(age_s last_allowed_at)
if [ -n "$allowed_age" ] && [ "$allowed_age" -lt $(( SETTLE_H * 3600 )) ]; then
	# NOT a refusal in the sense the rest of this file uses the word - nothing is
	# being deferred, the work is simply done. It still exits 1, because that is
	# the only way to tell ExecCondition= not to run the unit, and it deliberately
	# does not touch the defer counters.
	sset "last_run_at=$now_iso"
	printf 'update-when-idle: nothing to do - the update already ran %sh ago\n' \
		"$(( allowed_age / 3600 ))"
	exit 1
fi

# ------------------------------------------------------------------------------
# Is anyone watching?
# ------------------------------------------------------------------------------
# UNKNOWN PROCEEDS HERE, AND THAT IS THE OPPOSITE OF THE ENCODER GATE. In
# bin/reboot-when-staged.sh an unreadable measurement refuses, because "unknown
# is not idle" and the cost of a wrong reboot is a car journey. Here the cost of
# a wrong update is one interrupted stream, while the cost of failing closed is
# that a broken Jellyfin API silently stops all twenty-seven containers taking
# updates - with every unit healthy and nothing failed to say so.
#
# docs/observability.md already draws this line for the same reason: a stopped
# collector must never hold up a security update. The state file records the
# case separately so bin/verify-host.sh can WARN on it rather than it passing in
# silence, which is what makes proceeding a decision rather than a blind spot.
if ! watching=$("$ROOT/bin/jellyfin-watching.sh"); then
	sset "last_unknown_at=$now_iso"
	allow "jellyfin could not be asked whether anyone is watching - updating anyway, because a gate that cannot answer must not become a gate that never opens"
fi

if [ "${watching:-0}" -eq 0 ]; then
	allow "nobody is watching - updating"
fi

# ------------------------------------------------------------------------------
# Somebody is. How long has that been the answer?
# ------------------------------------------------------------------------------
since_age=$(age_s deferring_since)
since_d=$(( ${since_age:-0} / 86400 ))

if [ -n "$since_age" ] && [ "$since_d" -ge "$ESCALATE_DEFER_D" ]; then
	allow "$watching session(s) playing, but updates have been deferred for ${since_d}d of ${ESCALATE_DEFER_D} - updating anyway. A stream will be interrupted; Jellyfin has the position saved and the client resumes."
fi

refuse "$watching session(s) are playing (deferred ${since_d}d of ${ESCALATE_DEFER_D}; past that it updates anyway)" \
	"playback"
