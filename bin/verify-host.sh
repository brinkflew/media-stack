#!/usr/bin/env bash
# ==============================================================================
# Is this host actually healthy, or only reachable?
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, as `core`. This is the battery host/RUNBOOK.md signed the
# migration off with, made runnable, plus the checks that only matter once the
# host updates itself.
#
# An OS update changes the NVIDIA driver - it ships INSIDE the uCore image, and
# the move to stable-nvidia-lts took it 610.57.04 -> 580.173.02. A CDI spec
# names that version in dozens of paths, so "the GPUs work" is not something to
# infer from a container being Up. Both Jellyfin and tdarr-node-01 consume
# nvidia.com/gpu=1, and a stale spec surfaces as a failed transcode hours later.
#
# It writes /run/motd.d/40-media-stack.motd, so the result is the first thing an
# ssh session shows. THE MOTD CARRIES ITS OWN TIMESTAMP: a quiet MOTD and a
# checker that stopped running are otherwise indistinguishable, and the second
# one is the failure that hides every other failure.
#
# Usage:
#   bin/verify-host.sh              check, print, write the MOTD; exit 1 on FAIL
#   bin/verify-host.sh --quiet      MOTD only, no stdout - what the timer runs
#   bin/verify-host.sh --routes     also walk the public route battery (slow)
#   bin/verify-host.sh --greenboot  host-level checks ONLY, for greenboot
#
# --greenboot deliberately drops every container and user-manager check. It runs
# as root before the user session exists, and more importantly a greenboot check
# that fails rolls the whole deployment back: a slow Tdarr start must never be
# able to do that. It answers "did the OS come up correctly", nothing more.
# ==============================================================================

set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"

QUIET="" ROUTES="" GREENBOOT=""
while [ $# -gt 0 ]; do
	if   [ "${1:-}" = "--quiet" ];     then QUIET=1
	elif [ "${1:-}" = "--routes" ];    then ROUTES=1
	elif [ "${1:-}" = "--greenboot" ]; then GREENBOOT=1; QUIET=1
	else echo "verify-host: unknown argument: $1" >&2; exit 2
	fi
	shift
done

# Root when greenboot calls us, `core` otherwise. Passwordless sudo is available
# but -n means we never hang waiting for a password prompt nobody can answer.
if [ "$(id -u)" = 0 ]; then priv() { "$@"; }; else priv() { sudo -n "$@"; }; fi

fails=() warns=() notes=()
say()  { [ -n "$QUIET" ] || printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { [ -n "$QUIET" ] || printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { fails+=("$1"); [ -n "$QUIET" ] || printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
warn() { warns+=("$1"); [ -n "$QUIET" ] || printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
note() { notes+=("$1"); }

# ------------------------------------------------------------------------------
# The address, first. The router's 9122 -> 22 forward points at a fixed address,
# so if it moved you want to know inside the session you already have rather
# than discovering it the next time you try to connect.
# ------------------------------------------------------------------------------
say "Network"
if ip -4 -o addr show scope global | grep -q '192\.168\.0\.100/24'; then
	ok "192.168.0.100/24 held"
else
	bad "the LAN address moved - the router's port forward now points nowhere"
fi

# ------------------------------------------------------------------------------
# Deployment. `stage` means updates are downloaded and written but never applied
# unattended; the reboot is a separate, human act.
# ------------------------------------------------------------------------------
say "Deployment"
status_json=$(rpm-ostree status --json 2>/dev/null)
if [ -z "$status_json" ]; then
	bad "rpm-ostree status returned nothing"
	booted_ver="?" staged_ver="" pinned_count=0
else
	booted_ver=$(jq -r '.deployments[] | select(.booted) | .version' <<<"$status_json")
	booted_ref=$(jq -r '.deployments[] | select(.booted) | ."container-image-reference" // "-"' <<<"$status_json")
	staged_ver=$(jq -r '.deployments[] | select(.staged) | .version' <<<"$status_json")
	pinned_count=$(jq '[.deployments[] | select(.pinned)] | length' <<<"$status_json")
	depl_count=$(jq '.deployments | length' <<<"$status_json")

	ok "booted $booted_ver"

	# The whole point of a signed ref: the OS image is verified against ublue's
	# cosign keys rather than merely fetched over TLS.
	case "$booted_ref" in
		ostree-image-signed:*) ok "image signature verification is on" ;;
		*)                     warn "booted from an UNVERIFIED ref ($booted_ref)" ;;
	esac

	# Not the tag we think we are on is worth catching: stable-nvidia and
	# stable-nvidia-lts differ only by the NVIDIA driver branch, and the kernel
	# is identical, so nothing else would reveal a silent swap.
	case "$booted_ref" in
		*:stable-nvidia-lts) ok "tracking stable-nvidia-lts (driver 580 branch)" ;;
		*) warn "tracking an unexpected image: ${booted_ref##*ucore}" ;;
	esac

	[ "$pinned_count" -eq 0 ] || warn "$pinned_count deployment(s) PINNED - a forgotten pin fills /boot"
fi

# The effective policy, from rpm-ostree rather than from the file, so a config
# that failed to parse shows up as the default rather than as what we wrote.
policy=$(rpm-ostree status 2>/dev/null | sed -n 's/^AutomaticUpdates: *\([a-z]*\).*/\1/p')
if [ "$policy" = "stage" ]; then
	ok "automatic updates: stage (never reboots on its own)"
else
	bad "automatic update policy is '${policy:-none}', expected 'stage'"
fi

# THE CHECK THAT CATCHES A SILENTLY-STOPPED UPDATER. If ublue ever rotates its
# signing key, or /boot fills, nothing stages - and that is indistinguishable
# from a stream with no new releases unless the run's exit status is asserted.
if [ "$(systemctl is-enabled rpm-ostreed-automatic.timer 2>/dev/null)" = enabled ]; then
	ok "rpm-ostreed-automatic.timer enabled"
else
	bad "rpm-ostreed-automatic.timer is not enabled - nothing checks for updates"
fi
last_run=$(systemctl show rpm-ostreed-automatic.service -p ExecMainExitTimestamp --value 2>/dev/null)
last_rc=$(systemctl show rpm-ostreed-automatic.service -p ExecMainStatus --value 2>/dev/null)
if [ -z "$last_run" ]; then
	warn "the update check has never run"
else
	age_h=$(( ( $(date +%s) - $(date -d "$last_run" +%s) ) / 3600 ))
	if [ "${last_rc:-1}" != 0 ]; then
		bad "the last update check FAILED (exit $last_rc, ${age_h}h ago) - nothing is staging"
	elif [ "$age_h" -gt 48 ]; then
		bad "the last update check was ${age_h}h ago - the timer has stopped firing"
	else
		ok "last update check ${age_h}h ago, exit 0"
	fi
fi

# Only ONE updater may be armed. Two would both write deployments into a /boot
# that holds two kernels, and the loser fails overnight with nobody watching.
for u in zincati.service bootc-fetch-apply-updates.timer; do
	st=$(systemctl is-enabled "$u" 2>/dev/null || true)
	case "$st" in
		masked|disabled|"") ok "$u is $st" ;;
		*) bad "$u is $st - a second updater is armed" ;;
	esac
done

# /boot holds exactly two kernels and cannot be grown: nvme0n1p4 is XFS, which
# cannot be shrunk by any tool, so enlarging it means repartitioning the disk
# that carries config/.
boot_free=$(df -Pm /boot | awk 'NR==2 {print $4}')
if [ "$boot_free" -ge 160 ]; then
	ok "/boot ${boot_free}M free, ${depl_count:-?} deployment(s)"
else
	bad "/boot only ${boot_free}M free - the next staged update cannot write its kernel"
fi

# ------------------------------------------------------------------------------
# Storage. The label matters as much as the mount: without context= every
# container start would relabel 7.3 TB, so it is set once here and nowhere else.
# ------------------------------------------------------------------------------
say "Storage"
mopts=$(findmnt -n -o OPTIONS /var/mnt/media 2>/dev/null)
if [ -z "$mopts" ]; then
	bad "/var/mnt/media is not mounted"
elif [[ "$mopts" == *context=system_u:object_r:container_file_t:s0* ]]; then
	ok "/mnt/media mounted with the container SELinux label"
else
	bad "/mnt/media is mounted WITHOUT context= - containers cannot read it"
fi

# ------------------------------------------------------------------------------
# GPU and CDI. This is the group that does not exist anywhere else and is the
# reason this script was written.
# ------------------------------------------------------------------------------
say "GPU / CDI"
gpu_count=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)
if [ "${gpu_count:-0}" -eq 2 ]; then
	ok "2 GPUs visible to the host"
else
	bad "nvidia-smi lists ${gpu_count:-0} GPU(s), expected 2"
fi

# EXACTLY ONE SPEC. uCore ships nvidia-cdi-refresh.{path,service}, which writes
# /run/cdi/nvidia.yaml on tmpfs and regenerates it whenever the driver changes.
# A second, persistent copy in /etc/cdi survives the update that invalidates it,
# and two files defining nvidia.com/gpu=1 with different library paths is a
# conflict the resolver rejects rather than merges.
specs=()
[ -f /etc/cdi/nvidia.yaml ] && specs+=(/etc/cdi/nvidia.yaml)
[ -f /run/cdi/nvidia.yaml ] && specs+=(/run/cdi/nvidia.yaml)
case ${#specs[@]} in
	1) ok "one CDI spec (${specs[0]})" ;;
	0) bad "no CDI spec at all - no container can get a GPU" ;;
	*) bad "TWO CDI specs (${specs[*]}) - they will conflict at the next driver change" ;;
esac

# The spec hardcodes the driver version in dozens of paths, so a spec that was
# not regenerated points at libraries the update deleted.
if [ ${#specs[@]} -gt 0 ]; then
	spec_drv=$(grep -om1 'host-driver-version=[0-9.]*' "${specs[0]}" | cut -d= -f2)
	live_drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
	if [ -n "$spec_drv" ] && [ "$spec_drv" = "$live_drv" ]; then
		ok "CDI spec matches the running driver ($live_drv)"
	else
		bad "CDI spec names driver ${spec_drv:-?} but the running driver is ${live_drv:-?}"
	fi
fi

if systemctl is-active --quiet nvidia-cdi-refresh.path 2>/dev/null; then
	ok "nvidia-cdi-refresh.path is watching for driver changes"
else
	warn "nvidia-cdi-refresh.path is not active - the spec will go stale on update"
fi

# ------------------------------------------------------------------------------
# Host prerequisites. Every one of these has failed silently at least once.
# ------------------------------------------------------------------------------
say "Host prerequisites"

# Rootless Podman publishes through a userspace process that binds like any
# other daemon, so firewalld's INPUT rules apply normally - ports are closed by
# default here, which is the reverse of the Docker host.
fw_svc=$(priv firewall-cmd --list-services 2>/dev/null)
fw_prt=$(priv firewall-cmd --list-ports 2>/dev/null)
if [ -z "$fw_svc$fw_prt" ]; then
	warn "could not read firewalld (needs sudo -n)"
else
	for want in http https ssh; do
		case " $fw_svc " in *" $want "*) ;; *) bad "firewalld is missing the $want service" ;; esac
	done
	case " $fw_prt " in *" 8096/tcp "*) ok "firewalld allows http, https, ssh and 8096/tcp" ;;
		*) bad "firewalld is missing 8096/tcp - Jellyfin is unreachable on the LAN" ;; esac
fi

if [ "$(loginctl show-user core -p Linger --value 2>/dev/null)" = yes ]; then
	ok "lingering enabled - the stack starts without a login"
else
	bad "lingering is OFF - the stack will not start at boot"
fi

if [ "$(getsebool container_use_devices 2>/dev/null | awk '{print $3}')" = on ]; then
	ok "container_use_devices is on - gluetun can open /dev/net/tun"
else
	bad "container_use_devices is off - the VPN cannot create its TUN device"
fi

# io is NOT delegated by default, and an undelegated controller is accepted
# silently and does nothing. The failure is silence, so it must be asserted.
if [[ "$(systemctl show user@1000.service -p DelegateControllers --value 2>/dev/null)" == *io* ]]; then
	ok "the io controller is delegated - IOWeight= actually applies"
else
	bad "io is NOT delegated - every IOWeight= and IOReadBandwidthMax= is inert"
fi

sysfailed=$(systemctl list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -z "$sysfailed" ]; then ok "no failed system units"; else bad "failed system units: $(echo $sysfailed)"; fi

# ==============================================================================
# Everything below is the APPLICATION stack, and greenboot must not see it. A
# rollback triggered by a slow Tdarr start would be both wrong and invisible.
# ==============================================================================
if [ -z "$GREENBOOT" ]; then
	say "Container updates"

	# The same argument as rpm-ostreed-automatic above: a timer that has stopped
	# firing, or a run that failed, looks exactly like a week with no upstream
	# releases. There is no alerting here yet, so the MOTD is the channel - which
	# means the check has to exist rather than the failure being assumed visible.
	if [ "$(systemctl --user is-enabled podman-auto-update.timer 2>/dev/null)" = enabled ]; then
		ok "podman-auto-update.timer enabled"
	else
		bad "podman-auto-update.timer is not enabled - no container ever updates"
	fi
	au_run=$(systemctl --user show podman-auto-update.service -p ExecMainExitTimestamp --value 2>/dev/null)
	au_rc=$(systemctl --user show podman-auto-update.service -p ExecMainStatus --value 2>/dev/null)
	if [ -z "$au_run" ]; then
		warn "podman-auto-update has never run"
	else
		au_age=$(( ( $(date +%s) - $(date -d "$au_run" +%s) ) / 3600 ))
		if [ "${au_rc:-1}" != 0 ]; then
			bad "the last container update run FAILED (exit $au_rc, ${au_age}h ago)"
		elif [ "$au_age" -gt 48 ]; then
			bad "the last container update run was ${au_age}h ago - the timer has stopped"
		else
			ok "last container update run ${au_age}h ago, exit 0"
		fi
	fi

	# Caddy is built here, and `local` policy notices a new image without ever
	# producing one - so if this timer stops, Caddy silently stops updating while
	# every other service carries on.
	if [ "$(systemctl --user is-enabled media-stack-caddy-build.timer 2>/dev/null)" = enabled ]; then
		ok "media-stack-caddy-build.timer enabled"
	else
		bad "media-stack-caddy-build.timer is off - Caddy will never be rebuilt"
	fi

	# Every container that can be auto-updated should be. A unit that lost its
	# policy would simply never appear here again, silently.
	au_count=$(podman auto-update --dry-run 2>/dev/null | grep -cE 'registry|local' || true)
	if [ "${au_count:-0}" -ge 17 ]; then
		ok "$au_count containers carry an auto-update policy"
	else
		bad "only ${au_count:-0} containers carry an auto-update policy, expected 17"
	fi

	say "Containers"

	userfailed=$(systemctl --user list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
	if [ -z "$userfailed" ]; then ok "no failed user units"; else bad "failed user units: $(echo $userfailed)"; fi

	running=$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
	unhealthy=$(podman ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)
	if [ -z "$unhealthy" ]; then ok "$running containers up, none unhealthy"
	else bad "unhealthy: $(echo $unhealthy)"; fi

	# duckdns, unpackerr and the pod's infra container define no healthcheck.
	# A check that assumes all of them do reports those three broken for ever.
	for c in jellyfin tdarr-node-01; do
		if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
			if podman exec "$c" nvidia-smi -L 2>/dev/null | grep -q '^GPU '; then
				ok "$c can see its GPU"
			else
				bad "$c cannot see a GPU - check the CDI spec"
			fi
		else
			note "$c is not running, GPU not checked"
		fi
	done

	if [ -n "$ROUTES" ]; then
		say "Public routes"
		for h in watch request id auth sonarr radarr prowlarr tdarr torrent; do
			code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$h.avanserv.com/" 2>/dev/null)
			case "$code" in
				200|302|307) ok "$h -> $code" ;;
				*) bad "$h -> ${code:-no answer}" ;;
			esac
		done
	fi
fi

# ------------------------------------------------------------------------------
# The MOTD. Warnings only when warranted, plus two lines that are always there:
# a one-line summary, and when this last ran.
# ------------------------------------------------------------------------------
motd=/run/motd.d/40-media-stack.motd
{
	printf '  \033[1m── media-stack ─────────────────────────────────────────────────\033[0m\n'
	if [ -n "${staged_ver:-}" ]; then
		staged_age=""
		if [ -e /run/ostree/staged-deployment ]; then
			d=$(( ( $(date +%s) - $(stat -c %Y /run/ostree/staged-deployment) ) / 86400 ))
			staged_age=" (staged ${d}d ago)"
			[ "$d" -ge 7 ] && staged_age=" (staged ${d} DAYS ago - running a superseded image)"
		fi
		printf '  \033[33mOS UPDATE STAGED\033[0m  %s%s\n' "$staged_ver" "$staged_age"
		printf '      sudo systemctl reboot   — attended: be able to reach the machine\n'
	fi
	for f in ${fails+"${fails[@]}"}; do printf '  \033[31mFAIL\033[0m  %s\n' "$f"; done
	for w in ${warns+"${warns[@]}"}; do printf '  \033[33mWARN\033[0m  %s\n' "$w"; done
	printf '  %s · /boot %sM free · %s deployment(s)%s\n' \
		"${booted_ver:-?}" "${boot_free:-?}" "${depl_count:-?}" \
		"$([ "${pinned_count:-0}" -gt 0 ] && echo " · ${pinned_count} PINNED")"
	if [ -z "$GREENBOOT" ]; then
		printf '  %s containers up · driver %s\n' "${running:-?}" "${live_drv:-?}"
	fi
	printf '  \033[2mlast checked %s\033[0m\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
} | priv tee "$motd" >/dev/null 2>&1 || true

if [ ${#fails[@]} -gt 0 ]; then
	[ -n "$QUIET" ] || printf '\n\033[31m%d check(s) FAILED\033[0m\n' "${#fails[@]}"
	exit 1
fi
[ -n "$QUIET" ] || printf '\n\033[32mall checks passed\033[0m%s\n' \
	"$([ ${#warns[@]} -gt 0 ] && echo " (${#warns[@]} warning(s))")"
exit 0
