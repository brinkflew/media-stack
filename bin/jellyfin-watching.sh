#!/usr/bin/env bash
# ==============================================================================
# How many people would a Jellyfin restart interrupt right now?
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER. One question, two callers, so it is a script rather than a
# function copied into both:
#
#   bin/update-when-idle.sh      the ExecCondition= on podman-auto-update
#   bin/reboot-when-staged.sh    the Sunday reboot window
#
# Composed as a subprocess the way bin/pre-update-snapshot.sh calls
# bin/snapshot-databases.sh. It prints ONE NUMBER on stdout and says nothing
# else there, so a caller can read it with a command substitution.
#
#   bin/jellyfin-watching.sh              -> 2
#   bin/jellyfin-watching.sh --verbose    -> the same number, plus a breakdown
#                                            on stderr
#
# THE EXIT CODE CARRIES A THREE-WAY DISTINCTION, and it exists because the two
# callers want opposite things from the third case:
#
#   0  measured. The count is on stdout, and 0 is a real answer.
#   2  UNKNOWN. Jellyfin is running and could not be asked - no credential, no
#      HTTP client, a response that is not a session list. Nothing is printed.
#
# A container that is NOT RUNNING is 0, not unknown. There is no session to
# interrupt in a container that is already down, so treating that as unknown
# would make every gate refuse for as long as Jellyfin stayed stopped - a gate
# that is hardest to satisfy exactly when there is least reason for it.
#
# WHAT COUNTS AS WATCHING, and both halves were measured against the live API
# rather than assumed:
#
#   NowPlayingItem is not null      an idle client with the app merely open has
#                                   none, and is not watching anything. This is
#                                   the same test bin/collect-metrics.py's
#                                   source_playback makes for
#                                   home_server_jellyfin_sessions.
#
#   LastPlaybackCheckIn within      a client that vanished without telling the
#   CHECKIN_MAX_S                   server lingers in /Sessions with a frozen
#                                   check-in. Without this a ghost vetoes for
#                                   ever.
#
# A PAUSED STREAM COUNTS. Jellyfin preserves the position, so the cost of
# restarting under one is small - but someone who paused for two minutes to make
# tea is still watching, and a check-in stays fresh while paused, so IsPaused
# cannot be used to tell the two apart anyway. Measured: a paused Jellyfin Web
# client reports IsPaused true with LastPlaybackCheckIn equal to now.
#
# WHICH MEANS THE STALENESS FILTER IS NOT THE WHOLE ANSWER. A browser tab left
# open all night keeps checking in perfectly, and the series shows exactly that
# - one unbroken run of 18.4 hours. That case is broken by the CEILING in
# bin/update-when-idle.sh, not here. Two mechanisms, because they catch
# different things: this one drops clients that are gone, the ceiling drops
# clients that will never leave.
#
# IT CARRIES NO IDENTITY, and that is deliberate rather than incidental. See
# bin/collect-metrics.py's source_playback: a retained record of who watched
# what is surveillance of the household. A count is all a gate needs, and
# --verbose breaks it down by playback method only.
# ==============================================================================

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${HOME_SERVER_ENV_FILE:-$ROOT/.env}"

# A client checking in less often than this is treated as gone. Jellyfin's web
# and mobile clients check in every few seconds while a stream is loaded, paused
# included, so five minutes is many missed intervals rather than a near miss.
CHECKIN_MAX_S="${HOME_SERVER_CHECKIN_MAX_S:-300}"

VERBOSE=""
case "${1:-}" in
	"")        ;;
	--verbose) VERBOSE=1 ;;
	*)         echo "jellyfin-watching: unknown argument: $1" >&2; exit 64 ;;
esac

note() { [ -z "$VERBOSE" ] || printf 'jellyfin-watching: %s\n' "$1" >&2; }

# ------------------------------------------------------------------------------
# The override, which is the only way this gate's callers are testable
# ------------------------------------------------------------------------------
# The same argument HOME_SERVER_ENCODER_PCT makes in bin/reboot-when-staged.sh,
# and it is not hypothetical there: that branch was unprovable the first time it
# was tried because the transcode being used to test it finished mid-write. A
# gate that can only be exercised when somebody happens to be watching a film is
# a gate nobody exercises.
#
# `unknown` is spellable too, because the two callers disagree about what to do
# with it and both directions need proving.
if [ -n "${HOME_SERVER_WATCHING:-}" ]; then
	if [ "$HOME_SERVER_WATCHING" = unknown ]; then
		note "HOME_SERVER_WATCHING=unknown - reporting unknown without asking"
		exit 2
	fi
	note "HOME_SERVER_WATCHING=$HOME_SERVER_WATCHING - not asking Jellyfin"
	printf '%s\n' "$HOME_SERVER_WATCHING"
	exit 0
fi

# ------------------------------------------------------------------------------
# Is there anything to ask?
# ------------------------------------------------------------------------------
# `podman ps` rather than `systemctl is-active jellyfin`: the question is whether
# a session can exist, and only a RUNNING container can hold one. A unit that is
# activating - which jellyfin.service is for up to 1200s on a cold start, see
# TimeoutStartSec - has no sessions yet either way.
if [ -z "$(podman ps --filter name='^jellyfin$' --filter status=running \
           --format '{{.Names}}' 2>/dev/null)" ]; then
	note "jellyfin is not running - nothing to interrupt"
	echo 0
	exit 0
fi

key=$(sed -n 's/^JELLYFIN_API_KEY=//p' "$ENV_FILE" 2>/dev/null | tail -1)
key=${key%\"} key=${key#\"}
if [ -z "$key" ]; then
	note "JELLYFIN_API_KEY is not set in $ENV_FILE - cannot ask"
	exit 2
fi

# ------------------------------------------------------------------------------
# Ask
# ------------------------------------------------------------------------------
# THE CREDENTIAL GOES ON STDIN, NEVER ARGV. `curl -K -` reads its whole
# configuration from stdin, so the key never appears in the host's process list;
# `podman exec ... -H "X-Emby-Token: ..."` cannot avoid that. Lifted from
# api_get() in bin/collect-metrics.py, which makes the same call 288 times a day
# for the same reason.
#
# podman exec rather than the published LAN port, which Jellyfin does have. The
# rule is in host/systemd/README.md: a host-side unit reaches into any container
# whatever the network topology says, and nothing here has ever depended on the
# publish. Using it would make this the first script that does.
sessions=$(podman exec -i jellyfin curl -K - <<-EOF 2>/dev/null
	url = "http://localhost:8096/Sessions"
	header = "X-Emby-Token: $key"
	silent
	fail
	max-time = 8
EOF
)

if [ -z "$sessions" ]; then
	note "jellyfin is running but /Sessions returned nothing"
	exit 2
fi

# THE FRACTIONAL SECONDS ARE WHY THE sub() IS THERE. Jellyfin returns
# 2026-08-22T18:46:36.265195Z and jq's fromdateiso8601 accepts only whole
# seconds, so parsing the raw string throws and takes the whole filter with it.
# The `try`/`catch 0` behind it covers the never-played sentinel, which Jellyfin
# spells 0001-01-01T00:00:00.0000000Z - that falls far outside the window and is
# dropped, which is correct, but it must not raise on the way.
watching=$(printf '%s' "$sessions" | jq -e --argjson max "$CHECKIN_MAX_S" '
	if type != "array" then error("not a session list") else
	[ .[]
	  | select(.NowPlayingItem != null)
	  | select(
	      (now - ((.LastPlaybackCheckIn // "")
	              | sub("\\.[0-9]+"; "")
	              | try fromdateiso8601 catch 0)) <= $max)
	] | length
	end' 2>/dev/null)

if [ -z "$watching" ]; then
	note "/Sessions did not parse as a session list"
	exit 2
fi

if [ -n "$VERBOSE" ]; then
	# BY PLAYBACK METHOD ONLY. Same labels home_server_jellyfin_sessions carries,
	# and for the same reason - no user, no device, no title.
	printf '%s' "$sessions" | jq -r --argjson max "$CHECKIN_MAX_S" '
		[ .[]
		  | select(.NowPlayingItem != null)
		  | { m: (.PlayState.PlayMethod // "unknown" | ascii_downcase),
		      paused: (.PlayState.IsPaused == true),
		      fresh: ((now - ((.LastPlaybackCheckIn // "")
		                      | sub("\\.[0-9]+"; "")
		                      | try fromdateiso8601 catch 0)) <= $max) } ]
		| "with something loaded: \(length)",
		  "  fresh check-in:  \([.[] | select(.fresh)] | length)",
		  "  stale, ignored:  \([.[] | select(.fresh | not)] | length)",
		  "  paused:          \([.[] | select(.fresh and .paused)] | length)",
		  (group_by(.m)[] | "  method \(.[0].m): \(length)")' >&2
fi

printf '%s\n' "$watching"
