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
#
# It is silent on success and prints its FAILs to stderr, which is what puts the
# reason for a rollback in the journal rather than only in the MOTD.
# ==============================================================================

set -uo pipefail

# ${HOME:-/root} rather than $HOME, and that fallback is load-bearing rather than
# defensive. systemd gives a system service LANG and PATH and nothing else - HOME
# is NOT in the default environment - so under `set -u` a bare $HOME aborts bash
# on this line, before a single check runs. greenboot would then read exit 1 as a
# failed health check and roll back a perfectly good deployment, and because
# --greenboot implies --quiet it would do so with nothing in the journal saying
# why. It has never bitten because the only caller today is bin/reboot-host.sh,
# over ssh as `core`, where HOME is set.
export PATH="${HOME:-/root}/.local/bin:$PATH"

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

uptime_s=$(cut -d. -f1 /proc/uptime)

# Did a nightly oneshot run, and did it succeed?  Shared by the OS updater and
# the container one, because the failure mode is identical: a timer that stopped
# firing looks exactly like a quiet upstream, and the silence hides everything.
#
# ExecMainExitTimestamp is RUNTIME state and is wiped by a reboot, so "never
# run" and "not run since we booted twenty minutes ago" are indistinguishable
# from the unit alone. Warning on the second one means every reboot produces a
# false alarm for up to a day, which is exactly how a person learns to ignore
# this line. So it is only a finding once the machine has been up longer than
# the timer's period.
check_timer_run() {  # <label> <period-seconds> <unit> [--user]
	local label="$1" period="$2" unit="$3"
	local run rc age stale_h
	# An array rather than a bare $scope: the argument is absent for system
	# units, and an unquoted empty variable is the one spelling that both
	# disappears and splits on whitespace when it does not.
	local scope=()
	[ -z "${4:-}" ] || scope=("$4")
	run=$(systemctl "${scope[@]}" show "$unit" -p ExecMainExitTimestamp --value 2>/dev/null)
	rc=$(systemctl "${scope[@]}" show "$unit" -p ExecMainStatus --value 2>/dev/null)
	if [ -z "$run" ]; then
		if [ "$uptime_s" -lt "$period" ]; then
			ok "$label has not run since boot ($((uptime_s / 60))m ago) - not yet due"
		else
			bad "$label has never run, and this machine has been up $((uptime_s / 3600))h"
		fi
		return
	fi
	age=$(( ( $(date +%s) - $(date -d "$run" +%s) ) / 3600 ))
	# Stale at two periods, DERIVED rather than hardcoded. It used to be a flat
	# 48h, which happens to be two periods for the three nightly callers and is
	# wrong for anything else: pointed at the weekly reboot window it would have
	# gone red every Tuesday, so the period argument was half-used and the helper
	# could not express the timer it was most needed for.
	stale_h=$(( period * 2 / 3600 ))
	if [ "${rc:-1}" != 0 ]; then
		# No "- nothing is updating" tail here: this helper is shared with the
		# backup, and a failed backup run reporting that nothing is updating
		# sends you to look at entirely the wrong subsystem.
		bad "the last $label run FAILED (exit $rc, ${age}h ago)"
	elif [ "$age" -gt "$stale_h" ]; then
		bad "the last $label run was ${age}h ago - the timer has stopped firing"
	else
		ok "last $label run ${age}h ago, exit 0"
	fi
}

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
	# uCore's version string is the FCOS build date, and it does not move on
	# every image change - a rebase to a signed ref, or a week of package
	# updates, can leave it identical to the booted one. "OS UPDATE STAGED
	# 44.20260720.3.1" against a booted 44.20260720.3.1 reads as a no-op and
	# gets ignored, so carry the digest when the version cannot tell them apart.
	staged_dig=$(jq -r '.deployments[] | select(.staged) | .["base-checksum"] // .checksum // ""' <<<"$status_json" | cut -c1-8)
	staged_signed=$(jq -r '.deployments[] | select(.staged) | .["container-image-reference"] // ""' <<<"$status_json")
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
check_timer_run "OS update check" 86400 rpm-ostreed-automatic.service

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
elif [ "${pinned_count:-0}" -gt 0 ]; then
	# A PIN IS THE USUAL CAUSE, AND IT IS NOT THE SAME PROBLEM. Pinning the
	# booted deployment is free until you reboot; after that, if the deployment
	# you booted into carries a different initramfs, the pin is suddenly holding
	# a second full slot. A firmware bump alone is enough for that.
	#
	# Measured twice now, both times immediately after an attended reboot:
	# 171M free before, 26M after, and 171M again the moment the old deployment
	# was unpinned and `rpm-ostree cleanup -r` run.
	#
	# So this is self-inflicted, temporary, and fixed by the step that comes
	# next anyway - which makes it a WARN with the remedy attached, not a FAIL.
	# As a FAIL it told bin/reboot-host.sh that a perfectly good deployment was
	# bad, and that script's failure path advises a rollback.
	warn "/boot only ${boot_free}M free, but ${pinned_count} deployment(s) pinned - unpin and 'sudo rpm-ostree cleanup -r' reclaims it"
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

sysfailed=$(systemctl list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
if [ -z "$sysfailed" ]; then ok "no failed system units"; else bad "failed system units: $sysfailed"; fi

# ==============================================================================
# Everything below is the APPLICATION stack, and greenboot must not see it. A
# rollback triggered by a slow Tdarr start would be both wrong and invisible.
# ==============================================================================
if [ -z "$GREENBOOT" ]; then
	# ----------------------------------------------------------------------
	# What greenboot made of the last boot.
	# ----------------------------------------------------------------------
	# Deliberately OUTSIDE --greenboot, even though the subject is host-level:
	# this reads what the greenboot check wrote, so asserting it there would be
	# the check grading its own previous run.
	#
	# Every part of this fails quietly, which is the reason to assert it. A
	# check that has stopped running, a symlink that was never made, and a
	# rollback path that cannot fire all look exactly like a host that keeps
	# booting cleanly.
	say "Boot health"
	# Overridable so this section's own branches can be exercised without a
	# reboot. "Armed" is the claim here that fails silently, so being able to
	# test the logic that reports it is worth three variables.
	boot_state="${MEDIA_STACK_BOOT_STATE:-/var/lib/media-stack/boot-state}"
	gb_etc="${MEDIA_STACK_GREENBOOT_ETC:-/etc/greenboot}"
	gb_cfg="${MEDIA_STACK_GRUB_CUSTOM:-/boot/grub2/custom.cfg}"
	# THE BINARY, NOT /etc/greenboot, IS WHAT "INSTALLED" MEANS. /etc is
	# merged forward across deployments and can be created by hand, so it
	# survives a rollback to a deployment that has no greenboot in it - and
	# would then report an armed rollback that cannot happen. /usr is part of
	# the deployment, so the binary answers the question honestly.
	gb_bin="${MEDIA_STACK_GREENBOOT_BIN:-/usr/libexec/greenboot/greenboot}"

	# The loudest thing here. A red boot means a deployment was rejected, and
	# this mark is also what stops bin/reboot-when-staged.sh rebooting into the
	# same image tonight - so it is cleared by a person, not aged out.
	gb_red=$(sed -n 's/^red_boot_at=//p' "$boot_state" 2>/dev/null | tail -1)
	[ -z "$gb_red" ] || bad "greenboot REJECTED a boot at $gb_red - unattended reboots are held; clear red_boot_at in $boot_state once understood"

	if [ ! -x "$gb_bin" ]; then
		warn "greenboot is not installed - a bad deployment cannot roll itself back"
	elif [ ! -r "$boot_state" ]; then
		# NO VERDICT IS TWO DIFFERENT THINGS, and conflating them deadlocks.
		# If greenboot ran this boot and recorded nothing, the check is broken
		# and that is a finding. If it has not run at all - the state for the
		# whole of the boot in which greenboot was installed or enabled, since
		# that boot predates it - then there is simply nothing to report yet.
		#
		# Failing on the second one is a trap with no exit: bin/reboot-host.sh
		# refuses to reboot a host the battery calls unhealthy, and only a
		# reboot can produce the verdict whose absence made it unhealthy. Found
		# exactly that way, by the pre-flight correctly refusing.
		if [ -n "$(systemctl show greenboot-healthcheck.service -p ExecMainExitTimestamp --value 2>/dev/null)" ]; then
			bad "greenboot ran but recorded no verdict - is the check symlinked into /etc/greenboot/check/?"
		else
			warn "greenboot has not run since this boot - the next reboot is its first"
		fi
	else
		gb_result=$(sed -n 's/^greenboot_result=//p' "$boot_state" | tail -1)
		gb_at=$(sed -n 's/^greenboot_checked_at=//p' "$boot_state" | tail -1)
		gb_epoch=$(date -d "${gb_at:-@0}" +%s 2>/dev/null || echo 0)

		# Did it run THIS boot? A verdict older than the current boot means the
		# check silently stopped running, which is indistinguishable from a
		# healthy host unless the timestamps are compared. The uptime guard is
		# the same one check_timer_run uses: greenboot runs during the
		# multi-user transaction, so anything under five minutes is a race
		# against ourselves rather than a finding.
		if [ "$uptime_s" -gt 300 ] && [ "$gb_epoch" -lt "$(( $(date +%s) - uptime_s ))" ]; then
			bad "greenboot recorded no verdict for this boot (last was ${gb_at:-never}) - the check is not running"
		else
			case "$gb_result" in
				green)   ok "greenboot verified this boot healthy" ;;
				red)     bad "greenboot FAILED this boot's health check" ;;
				timeout) warn "greenboot's health check timed out - inconclusive, nothing was rolled back" ;;
				missing) warn "greenboot found no checkout to run - nothing was verified this boot" ;;
				*)       warn "greenboot recorded an unrecognised verdict '${gb_result:-none}'" ;;
			esac
		fi

		# ARMED IS TWO THINGS, AND EITHER MISSING IS SILENT. The check must be
		# in required.d - wanted.d only logs - AND the GRUB counter must exist,
		# because without the GRUB custom.cfg greenboot arms a boot_counter
		# that nothing counts down. Neither absence shows up anywhere else.
		if   [ -e "$gb_etc/check/required.d/40-media-stack.sh" ]; then gb_dir=required
		elif [ -e "$gb_etc/check/wanted.d/40-media-stack.sh" ];   then gb_dir=wanted
		else gb_dir=absent
		fi
		gb_grub=no
		[ -f "$gb_cfg" ] && gb_grub=yes

		# THE ORDERING DROP-IN, ASSERTED BY ITS EFFECT RATHER THAN ITS
		# PRESENCE. It was first shipped as a symlink into /var/media-stack,
		# where PID 1 cannot read it under SELinux: `systemctl cat` printed it
		# and none of it applied. Checking that the file exists would have
		# passed throughout. Ask systemd what it actually loaded instead.
		if systemctl show greenboot-healthcheck.service -p After --value 2>/dev/null | grep -q 'firewall-stack-ports.service'; then
			ok "greenboot's ordering drop-in is loaded"
		else
			bad "greenboot's ordering drop-in is NOT loaded - the check races the units it asserts"
		fi

		# Enabled is separate from installed, and FCOS ships
		# 99-default-disable.preset - so layering greenboot leaves every one of
		# its units disabled and nothing runs at boot. Silent, and it looks
		# exactly like a host that has never had a bad deployment.
		if [ "$(systemctl is-enabled greenboot-healthcheck.service 2>/dev/null)" = enabled ]; then
			ok "greenboot-healthcheck.service is enabled"
		else
			bad "greenboot-healthcheck.service is not enabled - no check runs at boot"
		fi

		if [ "$gb_dir" = absent ]; then
			bad "the media-stack check is in neither required.d nor wanted.d - greenboot is not checking this host"
		elif [ "$gb_dir" = required ] && [ "$gb_grub" = yes ] && [ "${depl_count:-0}" -lt 2 ]; then
			# ARMED WITH NOWHERE TO GO, which is the NORMAL state here rather
			# than a fault: an attended reboot ends in `rpm-ostree cleanup -r`,
			# so the host sits on one deployment until the next one stages. A
			# rollback is only possible in the window between staging and that
			# cleanup - which is also the only window in which a deployment can
			# be bad, so the cover is where it needs to be.
			#
			# A WARN rather than a FAIL because greenboot stops itself here. Seen
			# in the journal, on this host: "Boot counter exhausted but no
			# rollback trigger set - manual intervention required". The trigger
			# is set only on the first boot into a NEW deployment, so with one
			# deployment a red boot costs GREENBOOT_MAX_BOOT_ATTEMPTS reboots and
			# then stops, rather than looping.
			warn "greenboot is armed but there is only ${depl_count:-?} deployment - nothing to roll back to until one stages"
		elif [ "$gb_dir" = required ] && [ "$gb_grub" = yes ]; then
			ok "greenboot is armed - a failed check reverts the deployment"
		else
			warn "greenboot is observe-only (${gb_dir}.d, GRUB counter: ${gb_grub}) - a bad deployment will NOT roll back"
		fi
	fi

	# --------------------------------------------------------------------------
	# The reboot window. greenboot judges a deployment AFTER the reboot; this is
	# what decides there is one at all, so it belongs directly after greenboot's
	# verdict and before anything about containers.
	#
	# Its failure is silent by construction: if the timer stops, greenboot stays
	# armed, every container stays healthy, the battery stays green, and
	# deployments simply pile up unapplied - which is the exact failure greenboot
	# was layered to fix. Every other timer here already has this check; this one
	# was the only one without it.
	# --------------------------------------------------------------------------
	say "Reboot window"

	# Initialised unconditionally: the MOTD below reads it, that block also runs
	# under --greenboot, and `set -u` is on.
	reboot_next=""
	if [ "$(systemctl --user is-enabled media-stack-reboot.timer 2>/dev/null)" = enabled ]; then
		ok "media-stack-reboot.timer enabled"
		# Computed HERE rather than in the MOTD block, because that block also
		# runs under --greenboot - as root, at boot, where there is no
		# XDG_RUNTIME_DIR and `systemctl --user` cannot answer at all.
		reboot_next=$(systemctl --user list-timers media-stack-reboot.timer \
			--no-legend --no-pager 2>/dev/null | awk 'NR==1 {print $1, $2, $3, $4}')
	else
		bad "media-stack-reboot.timer is not enabled - a staged deployment would never be applied"
	fi

	# A WEEK, not a night. The unit fires five times on a Sunday morning and in
	# the ordinary case refuses on all five, because nothing is staged; what this
	# asserts is that the group ran at all. Possible only since check_timer_run
	# started deriving its staleness threshold from the period it is given.
	check_timer_run "unattended reboot window" 604800 media-stack-reboot.service --user

	# THE MARKER FINALLY EARNING ITS KEEP. bin/reboot-when-staged.sh writes this
	# immediately before rebooting, because afterwards there is no process left
	# to write anything - and until now nothing read it, so "the window applied
	# an update on Sunday" and "the window has not fired since March" still
	# looked identical from this side. It is also the only thing that
	# distinguishes an unattended reboot from a power cut.
	unatt=$(sed -n 's/^unattended_reboot_at=//p' "$boot_state" 2>/dev/null | tail -1)
	if [ -z "$unatt" ]; then
		ok "the reboot window has not applied a deployment yet"
	else
		unatt_epoch=$(date -d "$unatt" +%s 2>/dev/null || echo 0)
		boot_epoch=$(( $(date +%s) - uptime_s ))
		# A window rather than an equality: the mark is written seconds before
		# `systemctl reboot` and the boot that follows takes as long as it takes.
		if [ "$unatt_epoch" -le "$boot_epoch" ] && [ "$unatt_epoch" -gt "$(( boot_epoch - 600 ))" ]; then
			ok "this boot was applied by the unattended window at $unatt"
		else
			ok "the reboot window last applied a deployment at $unatt"
		fi
	fi

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
	check_timer_run "container update" 86400 podman-auto-update.service --user

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

	# ------------------------------------------------------------------------------
	say "Backups"
	# ------------------------------------------------------------------------------
	# config/ is the only thing here that cannot be rebuilt from git, and until
	# 2026-08-14 the backup ran on the workstation by hand - so a fortnight away
	# was a fortnight with no backups, and nothing said so. It now runs here
	# nightly, which means the failure mode moved rather than disappearing: a
	# timer that stopped firing, or an off-site key that stopped working, looks
	# exactly like everything being fine.
	#
	# bin/backup-server.sh writes the marker below after each leg. Reading the
	# repositories directly would be better, except the off-site one is a network
	# call with credentials, and this runs every hour.
	if [ "$(systemctl --user is-enabled media-stack-backup.timer 2>/dev/null)" = enabled ]; then
		ok "media-stack-backup.timer enabled"
	else
		bad "media-stack-backup.timer is not enabled - config/ is not being backed up"
	fi
	check_timer_run "backup" 86400 media-stack-backup.service --user

	# Same ${HOME:-} guard as line 42. This branch only runs as `core`, where
	# HOME is always set, but an unbound expansion aborts the whole script
	# under `set -u` and that is too sharp an edge to leave lying around.
	backup_state="${HOME:-/root}/.cache/media-stack/backup-state"
	# <label> <key> <max-hours> <severity>
	check_backup_age() {
		local label="$1" key="$2" max="$3" sev="$4" at age
		at=$(sed -n "s/^${key}=//p" "$backup_state" 2>/dev/null | tail -1)
		if [ -z "$at" ]; then
			# Same argument as check_timer_run: on a host that has just been
			# rebuilt this is true and uninteresting, and a finding nobody can
			# act on is how someone learns to ignore this whole block.
			if [ "$uptime_s" -lt 86400 ]; then
				ok "no $label recorded yet (up $((uptime_s / 60))m) - not yet due"
			else
				bad "no $label has EVER been recorded"
			fi
			return
		fi
		age=$(( ( $(date +%s) - $(date -d "$at" +%s) ) / 3600 ))
		if [ "$age" -le "$max" ]; then
			ok "$label ${age}h ago"
		else
			"$sev" "the $label is ${age}h old (limit ${max}h)"
		fi
	}
	# The local copy is on the same disk as config/, so it is the weaker of the
	# two: it covers a bad change, not a dead disk. The off-site one is the copy
	# that survives nvme0n1, which is why its ceiling is tight as well.
	check_backup_age "local backup"    local_at   48 bad
	check_backup_age "off-site backup" offsite_at 72 bad
	# The server's key cannot delete, deliberately - so nothing here prunes the
	# off-site repository and it grows until the workstation runs
	# bin/backup-offsite.sh. Slow, but unbounded if nobody ever does.
	check_backup_age "off-site prune" offsite_pruned_at 720 warn
	# "Cannot delete" is the whole reason the server is allowed to hold a backup
	# credential at all, and it is enforced by an ABSENCE - nothing grants delete
	# outside locks/, so there is no Deny statement to eyeball and a policy that
	# has silently widened looks exactly like one that works. It also lives
	# outside this repository, in Scaleway's bucket and IAM policies, where a
	# console edit or a key rotation can change it with nothing here noticing.
	# backup-server.sh therefore re-proves it nightly and writes this marker only
	# on a confirmed refusal; 48h matches the local ceiling, so one unreachable
	# night is tolerated and a real drift surfaces on the second.
	check_backup_age "off-site delete denial" offsite_policy_ok_at 48 bad

	# ------------------------------------------------------------------------------
	say "Checkout"
	# ------------------------------------------------------------------------------
	# Containers update themselves nightly and the OS stages itself nightly, but
	# the unit definitions only move when a human types `git pull` - so this is
	# the one part of the system with no automation and no feedback. The remote
	# has drifted from git before, and an edit made over ssh is invisible until
	# the next pull refuses with "local changes would be overwritten".
	repo=/var/media-stack
	dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
	if [ -z "$dirty" ]; then
		ok "checkout is clean"
	else
		bad "LOCAL CHANGES on the server: $(echo "$dirty" | awk '{print $2}' | tr '\n' ' ')"
	fi

	# ls-remote rather than fetch: it writes nothing into .git, so this script
	# stays read-only apart from the MOTD. The cost is that it cannot tell ahead
	# from behind - only that the two differ, which is the thing worth saying.
	local_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
	remote_head=$(git -C "$repo" ls-remote origin HEAD 2>/dev/null | awk '{print $1}')
	if [ -z "$remote_head" ]; then
		note "could not reach origin - not a health problem"
	elif [ "$local_head" = "$remote_head" ]; then
		ok "checkout matches origin"
	else
		warn "checkout is not at origin (local ${local_head:0:7}, origin ${remote_head:0:7})"
	fi

	say "Containers"

	userfailed=$(systemctl --user list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
	if [ -z "$userfailed" ]; then ok "no failed user units"; else bad "failed user units: $userfailed"; fi

	running=$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
	unhealthy=$(podman ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | paste -sd' ' -)
	if [ -z "$unhealthy" ]; then ok "$running containers up, none unhealthy"
	else bad "unhealthy: $unhealthy"; fi

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
	printf '  \033[1m-- media-stack -------------------------------------------------\033[0m\n'
	if [ -n "${staged_ver:-}" ]; then
		staged_age=""
		if [ -e /run/ostree/staged-deployment ]; then
			d=$(( ( $(date +%s) - $(stat -c %Y /run/ostree/staged-deployment) ) / 86400 ))
			staged_age=" (staged ${d}d ago)"
			[ "$d" -ge 7 ] && staged_age=" (staged ${d} DAYS ago - running a superseded image)"
		fi
		label="$staged_ver"
		[ "$staged_ver" = "${booted_ver:-}" ] && [ -n "$staged_dig" ] && label="$staged_ver @$staged_dig"
		case "$staged_signed" in ostree-image-signed:*) label="$label signed" ;; esac
		printf '  \033[33mOS UPDATE STAGED\033[0m  %s%s\n' "$label" "$staged_age"
		# NAME THE UNATTENDED ROUTE FIRST, because it is now the one that
		# usually applies this. Saying only "sudo systemctl reboot - attended"
		# reads as "nothing will happen until you do this", which stopped being
		# true when media-stack-reboot.timer was armed.
		#
		# gb_red is empty under --greenboot (that section does not run), so the
		# held branch simply never fires there - correct, since the MOTD it
		# would be writing belongs to a boot that is still being judged.
		if [ -n "${gb_red:-}" ]; then
			printf '      HELD - a deployment was rejected at %s; the window will not fire until that is cleared\n' "$gb_red"
		elif [ -n "${reboot_next:-}" ]; then
			printf '      unattended: %s   (Sun 05:00-09:00, if nothing is transcoding)\n' "$reboot_next"
		fi
		printf '      sudo systemctl reboot   - or attended, now: be able to reach the machine\n'
	fi
	for f in ${fails+"${fails[@]}"}; do printf '  \033[31mFAIL\033[0m  %s\n' "$f"; done
	for w in ${warns+"${warns[@]}"}; do printf '  \033[33mWARN\033[0m  %s\n' "$w"; done
	printf '  %s -- /boot %sM free -- %s deployment(s)%s\n' \
		"${booted_ver:-?}" "${boot_free:-?}" "${depl_count:-?}" \
		"$([ "${pinned_count:-0}" -gt 0 ] && echo " -- ${pinned_count} PINNED")"
	if [ -z "$GREENBOOT" ]; then
		printf '  %s containers up -- driver %s\n' "${running:-?}" "${live_drv:-?}"
	fi
	printf '  \033[2mlast checked %s\033[0m\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
} | priv tee "$motd" >/dev/null 2>&1 || true

if [ ${#fails[@]} -gt 0 ]; then
	# UNDER --greenboot, SAY WHY ON STDERR. greenboot captures the check's
	# output into the journal, and --greenboot implies --quiet - so without
	# this a red boot is recorded as "exited 1" and the reason exists only in
	# a MOTD that, if the rollback fires, belongs to a deployment nobody is
	# running any more. Colour is deliberately omitted: this goes to the
	# journal, not a terminal.
	if [ -n "$GREENBOOT" ]; then
		for f in "${fails[@]}"; do printf 'verify-host: FAIL %s\n' "$f" >&2; done
	fi
	[ -n "$QUIET" ] || printf '\n\033[31m%d check(s) FAILED\033[0m\n' "${#fails[@]}"
	exit 1
fi
[ -n "$QUIET" ] || printf '\n\033[32mall checks passed\033[0m%s\n' \
	"$([ ${#warns[@]} -gt 0 ] && echo " (${#warns[@]} warning(s))")"
exit 0
