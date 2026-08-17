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
# It writes /run/motd.d/40-home-server.motd, so the result is the first thing an
# ssh session shows. THE MOTD CARRIES ITS OWN TIMESTAMP: a quiet MOTD and a
# checker that stopped running are otherwise indistinguishable, and the second
# one is the failure that hides every other failure.
#
# It also writes /var/lib/home-server/status.json on every non-greenboot run -
# the same findings, keyed by a STABLE ID rather than by prose, for a dashboard
# to read. That file is additionally this script's own durable record: it was
# the only automated job here that wrote no marker of its last success, and a
# MOTD on tmpfs does not survive a reboot.
#
# Usage:
#   bin/verify-host.sh              check, print, write the MOTD; exit 1 on FAIL
#   bin/verify-host.sh --quiet      MOTD only, no stdout - what the timer runs
#   bin/verify-host.sh --json       the same findings as JSON on stdout
#   bin/verify-host.sh --routes     also walk the public route battery (slow)
#   bin/verify-host.sh --greenboot  host-level checks ONLY, for greenboot
#
# --greenboot deliberately drops every container and user-manager check. It runs
# as root before the user session exists, and more importantly a greenboot check
# that fails rolls the whole deployment back: a slow Tdarr start must never be
# able to do that. It answers "did the OS come up correctly", nothing more.
#
# It is silent on success and prints its FAILs to stderr, which is what puts the
# reason for a rollback in the journal rather than only in the MOTD. It writes no
# JSON at all, and --json --greenboot together is an error: that mode's stdout
# and exit code are load-bearing in the rollback decision.
#
# Overrides, for exercising branches without waiting for the real thing:
#   HOME_SERVER_STATUS_FILE   where status.json goes
#   HOME_SERVER_BOOT_STATE    greenboot's verdict file
#   HOME_SERVER_GREENBOOT_BIN / _ETC, HOME_SERVER_GRUB_CUSTOM
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

QUIET="" ROUTES="" GREENBOOT="" JSON=""
while [ $# -gt 0 ]; do
	if   [ "${1:-}" = "--quiet" ];     then QUIET=1
	elif [ "${1:-}" = "--routes" ];    then ROUTES=1
	elif [ "${1:-}" = "--json" ];      then JSON=1; QUIET=1
	elif [ "${1:-}" = "--greenboot" ]; then GREENBOOT=1; QUIET=1
	else echo "verify-host: unknown argument: $1" >&2; exit 2
	fi
	shift
done

# Refused rather than silently ignored. Under --greenboot this script's stdout
# is where the reason for an OS rollback is recorded, and its exit code is what
# decides on one - so a JSON document on that stream would displace the only
# legible account of why the machine reverted. See the emit block at the end.
if [ -n "$JSON" ] && [ -n "$GREENBOOT" ]; then
	echo "verify-host: --json and --greenboot are mutually exclusive" >&2
	exit 2
fi

# Root when greenboot calls us, `core` otherwise. Passwordless sudo is available
# but -n means we never hang waiting for a password prompt nobody can answer.
if [ "$(id -u)" = 0 ]; then priv() { "$@"; }; else priv() { sudo -n "$@"; }; fi

# ------------------------------------------------------------------------------
# Findings, and their machine-readable shadow
# ------------------------------------------------------------------------------
# THE FIRST ARGUMENT IS A STABLE ID; THE PROSE IS NOT. A dashboard keys on
# `cdi.driver_match` and never on the sentence after it, so rewording a message
# whenever the message is wrong costs nothing. The id is a bare word rather than
# a quoted string so it reads as a key rather than as more prose, and so
# bin/lint-repo.sh can grep the whole set out and prove it is unique.
#
# PARALLEL ARRAYS rather than one array of delimited records. Not because a
# delimiter would be hard to pick, but because the encoding then lives in one
# place - the emit block - instead of at 95 call sites.
fails=() warns=() notes=()
sect_id=() sect_title=()
chk_sect=() chk_id=() chk_status=() chk_msg=()
fact_k=() fact_t=() fact_v=()
cur_sect=none

record() {  # <status> <id> <message>
	chk_sect+=("$cur_sect") chk_id+=("$2") chk_status+=("$1") chk_msg+=("$3")
}
say()  { cur_sect="$1"; sect_id+=("$1") sect_title+=("$2")
         [ -n "$QUIET" ] || printf '\n\033[1m==> %s\033[0m\n' "$2"; }
ok()   { record pass "$1" "$2"; [ -n "$QUIET" ] || printf '  \033[32mPASS\033[0m  %s\n' "$2"; }
bad()  { record fail "$1" "$2"; fails+=("$2"); [ -n "$QUIET" ] || printf '  \033[31mFAIL\033[0m  %s\n' "$2"; }
warn() { record warn "$1" "$2"; warns+=("$2"); [ -n "$QUIET" ] || printf '  \033[33mWARN\033[0m  %s\n' "$2"; }
note() { record note "$1" "$2"; notes+=("$2"); }

# A number a dashboard would otherwise have to parse back out of prose. Type is
# str (default), num or bool; an EMPTY value becomes JSON null, which is how
# "not measured" stays distinct from zero.
#
# ALWAYS PASS ${var:-}. Under `set -u` a fact() naming a variable some branch
# did not set aborts the script - after every check has run and before the MOTD
# is written, with an exit code bin/reboot-host.sh reads as an unhealthy host.
# That is the sharpest edge in this file.
fact() { fact_k+=("$1") fact_t+=("${3:-str}") fact_v+=("$2"); }

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
check_timer_run() {  # <id> <label> <period-seconds> <unit> [--user]
	local id="$1" label="$2" period="$3" unit="$4"
	local run rc age stale_h
	# An array rather than a bare $scope: the argument is absent for system
	# units, and an unquoted empty variable is the one spelling that both
	# disappears and splits on whitespace when it does not.
	local scope=()
	[ -z "${5:-}" ] || scope=("$5")
	run=$(systemctl "${scope[@]}" show "$unit" -p ExecMainExitTimestamp --value 2>/dev/null)
	rc=$(systemctl "${scope[@]}" show "$unit" -p ExecMainStatus --value 2>/dev/null)
	if [ -z "$run" ]; then
		if [ "$uptime_s" -lt "$period" ]; then
			ok "$id" "$label has not run since boot ($((uptime_s / 60))m ago) - not yet due"
		else
			bad "$id" "$label has never run, and this machine has been up $((uptime_s / 3600))h"
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
		bad "$id" "the last $label run FAILED (exit $rc, ${age}h ago)"
	elif [ "$age" -gt "$stale_h" ]; then
		bad "$id" "the last $label run was ${age}h ago - the timer has stopped firing"
	else
		ok "$id" "last $label run ${age}h ago, exit 0"
	fi
}

# ------------------------------------------------------------------------------
# The address, first. The router's 9122 -> 22 forward points at a fixed address,
# so if it moved you want to know inside the session you already have rather
# than discovering it the next time you try to connect.
# ------------------------------------------------------------------------------
say net "Network"
if ip -4 -o addr show scope global | grep -q '192\.168\.0\.100/24'; then
	ok net.lan_address "192.168.0.100/24 held"
else
	bad net.lan_address "the LAN address moved - the router's port forward now points nowhere"
fi

# ------------------------------------------------------------------------------
# Deployment. `stage` means updates are downloaded and written but never applied
# unattended; the reboot is a separate, human act.
# ------------------------------------------------------------------------------
say deploy "Deployment"
status_json=$(rpm-ostree status --json 2>/dev/null)
if [ -z "$status_json" ]; then
	bad deploy.booted "rpm-ostree status returned nothing"
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

	ok deploy.booted "booted $booted_ver"

	# The whole point of a signed ref: the OS image is verified against ublue's
	# cosign keys rather than merely fetched over TLS.
	case "$booted_ref" in
		ostree-image-signed:*) ok deploy.image_signed "image signature verification is on" ;;
		*)                     warn deploy.image_signed "booted from an UNVERIFIED ref ($booted_ref)" ;;
	esac

	# Not the tag we think we are on is worth catching: stable-nvidia and
	# stable-nvidia-lts differ only by the NVIDIA driver branch, and the kernel
	# is identical, so nothing else would reveal a silent swap.
	case "$booted_ref" in
		*:stable-nvidia-lts) ok deploy.image_tag "tracking stable-nvidia-lts (driver 580 branch)" ;;
		*) warn deploy.image_tag "tracking an unexpected image: ${booted_ref##*ucore}" ;;
	esac

	# An if/else rather than the `||` this used to be. A check that speaks only
	# when it fails is, from the JSON's side, indistinguishable from a check
	# that did not run - so every id now reports on both branches.
	if [ "$pinned_count" -eq 0 ]; then
		ok deploy.pinned "no deployment is pinned"
	else
		warn deploy.pinned "$pinned_count deployment(s) PINNED - a forgotten pin fills /boot"
	fi
fi

# OUTSIDE the if/else on purpose, so these keys are present-and-null when
# rpm-ostree returned nothing rather than vanishing from the document. A
# dashboard can then tell "not measured" from "measured as empty"; a key that
# comes and goes forces it to guess.
fact booted_version  "${booted_ver:-}"
fact staged_version  "${staged_ver:-}"
fact deployments     "${depl_count:-}"   num
fact pinned          "${pinned_count:-}" num

# The effective policy, from rpm-ostree rather than from the file, so a config
# that failed to parse shows up as the default rather than as what we wrote.
policy=$(rpm-ostree status 2>/dev/null | sed -n 's/^AutomaticUpdates: *\([a-z]*\).*/\1/p')
if [ "$policy" = "stage" ]; then
	ok deploy.update_policy "automatic updates: stage (never reboots on its own)"
else
	bad deploy.update_policy "automatic update policy is '${policy:-none}', expected 'stage'"
fi

# THE CHECK THAT CATCHES A SILENTLY-STOPPED UPDATER. If ublue ever rotates its
# signing key, or /boot fills, nothing stages - and that is indistinguishable
# from a stream with no new releases unless the run's exit status is asserted.
if [ "$(systemctl is-enabled rpm-ostreed-automatic.timer 2>/dev/null)" = enabled ]; then
	ok deploy.update_timer "rpm-ostreed-automatic.timer enabled"
else
	bad deploy.update_timer "rpm-ostreed-automatic.timer is not enabled - nothing checks for updates"
fi
check_timer_run deploy.update_run "OS update check" 86400 rpm-ostreed-automatic.service

# Only ONE updater may be armed. Two would both write deployments into a /boot
# that holds two kernels, and the loser fails overnight with nobody watching.
#
# The list is id:unit pairs rather than bare unit names, because the id cannot
# be derived from the unit: bootc-fetch-apply-updates.timer would mangle into
# something nobody would grep for.
for pair in deploy.rival_zincati:zincati.service \
            deploy.rival_bootc:bootc-fetch-apply-updates.timer; do
	id="${pair%%:*}" u="${pair#*:}"
	st=$(systemctl is-enabled "$u" 2>/dev/null || true)
	case "$st" in
		masked|disabled|"") ok "$id" "$u is $st" ;;
		*) bad "$id" "$u is $st - a second updater is armed" ;;
	esac
done

# /boot holds exactly two kernels and cannot be grown: nvme0n1p4 is XFS, which
# cannot be shrunk by any tool, so enlarging it means repartitioning the disk
# that carries config/.
boot_free=$(df -Pm /boot | awk 'NR==2 {print $4}')
fact boot_free_mb "${boot_free:-}" num
if [ -z "$boot_free" ]; then
	# Guarded because the comparison below is a bare -ge on this value: an
	# unreadable df left it empty, `[` errored on the missing operand, and the
	# elif chain then emitted a finding with an empty number - on the code path
	# that decides whether the OS rolls itself back.
	note deploy.boot_free "/boot free space could not be read - not measured"
elif [ "$boot_free" -ge 160 ]; then
	ok deploy.boot_free "/boot ${boot_free}M free, ${depl_count:-?} deployment(s)"
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
	warn deploy.boot_free "/boot only ${boot_free}M free, but ${pinned_count} deployment(s) pinned - unpin and 'sudo rpm-ostree cleanup -r' reclaims it"
elif [ -n "$GREENBOOT" ]; then
	# A ROLLBACK CANNOT FIX A FULL /boot. It makes it worse: the deployment
	# being rolled back to needs its own slot. So under --greenboot this must
	# not be a FAIL, whatever the cause - the same rule the Logs and Metrics
	# sections already follow, and which the pin branch above applies for one
	# specific cause without ever generalising it.
	#
	# It cost a healthy boot on 2026-08-16. Three deployments had accumulated,
	# /boot hit 26M, this check FAILed, greenboot marked the boot red - and then
	# could not act on its own verdict: "Boot counter exhausted but no rollback
	# trigger set - manual intervention required".
	#
	# Nothing is lost by softening it here. The full battery still FAILs, so it
	# reaches the MOTD and status.json hourly, and both reboot paths refuse on
	# their own df: bin/reboot-host.sh gates its pre-flight on the FULL battery
	# and re-checks /boot itself, and bin/reboot-when-staged.sh does the same.
	warn deploy.boot_free "/boot only ${boot_free}M free - the next staged update cannot write its kernel, but a rollback would need a slot of its own and make it worse"
else
	bad deploy.boot_free "/boot only ${boot_free}M free - the next staged update cannot write its kernel"
fi

# ------------------------------------------------------------------------------
# Storage. The label matters as much as the mount: without context= every
# container start would relabel 7.3 TB, so it is set once here and nowhere else.
# ------------------------------------------------------------------------------
say storage "Storage"
mopts=$(findmnt -n -o OPTIONS /var/mnt/media 2>/dev/null)
if [ -z "$mopts" ]; then
	bad storage.media_mount "/var/mnt/media is not mounted"
elif [[ "$mopts" == *context=system_u:object_r:container_file_t:s0* ]]; then
	ok storage.media_mount "/mnt/media mounted with the container SELinux label"
else
	bad storage.media_mount "/mnt/media is mounted WITHOUT context= - containers cannot read it"
fi

# ------------------------------------------------------------------------------
# GPU and CDI. This is the group that does not exist anywhere else and is the
# reason this script was written.
# ------------------------------------------------------------------------------
say gpu_cdi "GPU / CDI"
gpu_count=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)
fact gpu_count "${gpu_count:-}" num
if [ "${gpu_count:-0}" -eq 2 ]; then
	ok gpu.count "2 GPUs visible to the host"
else
	bad gpu.count "nvidia-smi lists ${gpu_count:-0} GPU(s), expected 2"
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
	1) ok cdi.spec_count "one CDI spec (${specs[0]})" ;;
	0) bad cdi.spec_count "no CDI spec at all - no container can get a GPU" ;;
	*) bad cdi.spec_count "TWO CDI specs (${specs[*]}) - they will conflict at the next driver change" ;;
esac

# The spec hardcodes the driver version in dozens of paths, so a spec that was
# not regenerated points at libraries the update deleted.
if [ ${#specs[@]} -gt 0 ]; then
	spec_drv=$(grep -om1 'host-driver-version=[0-9.]*' "${specs[0]}" | cut -d= -f2)
	live_drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
	if [ -n "$spec_drv" ] && [ "$spec_drv" = "$live_drv" ]; then
		ok cdi.driver_match "CDI spec matches the running driver ($live_drv)"
	else
		bad cdi.driver_match "CDI spec names driver ${spec_drv:-?} but the running driver is ${live_drv:-?}"
	fi
fi

fact driver_version "${live_drv:-}"

if systemctl is-active --quiet nvidia-cdi-refresh.path 2>/dev/null; then
	ok cdi.refresh_watcher "nvidia-cdi-refresh.path is watching for driver changes"
else
	warn cdi.refresh_watcher "nvidia-cdi-refresh.path is not active - the spec will go stale on update"
fi

# ------------------------------------------------------------------------------
# Host prerequisites. Every one of these has failed silently at least once.
# ------------------------------------------------------------------------------
say host "Host prerequisites"

# Rootless Podman publishes through a userspace process that binds like any
# other daemon, so firewalld's INPUT rules apply normally - ports are closed by
# default here, which is the reverse of the Docker host.
fw_svc=$(priv firewall-cmd --list-services 2>/dev/null)
fw_prt=$(priv firewall-cmd --list-ports 2>/dev/null)
#
# COLLECTED INTO ONE FINDING rather than emitted per rule. This used to print up
# to three separate `bad`s and one collective `ok`, so the outcomes and the
# checks did not line up: there is no id that is emitted on every path when four
# calls can fire in six combinations. Naming what is missing in a single message
# says the same thing, and means host.firewalld reports exactly once whatever
# happens - including the unreadable case, which is the same question answered
# "do not know" rather than a different question.
fw_missing=""
if [ -z "$fw_svc$fw_prt" ]; then
	warn host.firewalld "could not read firewalld (needs sudo -n)"
else
	for want in http https ssh; do
		case " $fw_svc " in *" $want "*) ;; *) fw_missing="$fw_missing $want" ;; esac
	done
	case " $fw_prt " in *" 8096/tcp "*) ;; *) fw_missing="$fw_missing 8096/tcp" ;; esac
	if [ -z "$fw_missing" ]; then
		ok host.firewalld "firewalld allows http, https, ssh and 8096/tcp"
	else
		bad host.firewalld "firewalld is missing:$fw_missing - 8096/tcp means Jellyfin is unreachable on the LAN"
	fi
fi

if [ "$(loginctl show-user core -p Linger --value 2>/dev/null)" = yes ]; then
	ok host.linger "lingering enabled - the stack starts without a login"
else
	bad host.linger "lingering is OFF - the stack will not start at boot"
fi

if [ "$(getsebool container_use_devices 2>/dev/null | awk '{print $3}')" = on ]; then
	ok host.container_use_devices "container_use_devices is on - gluetun can open /dev/net/tun"
else
	bad host.container_use_devices "container_use_devices is off - the VPN cannot create its TUN device"
fi

# io is NOT delegated by default, and an undelegated controller is accepted
# silently and does nothing. The failure is silence, so it must be asserted.
if [[ "$(systemctl show user@1000.service -p DelegateControllers --value 2>/dev/null)" == *io* ]]; then
	ok host.io_delegated "the io controller is delegated - IOWeight= actually applies"
else
	bad host.io_delegated "io is NOT delegated - every IOWeight= and IOReadBandwidthMax= is inert"
fi

# UNDER --greenboot, THE UNIT RUNNING THIS CHECK IS NOT EVIDENCE ABOUT IT.
# greenboot-healthcheck.service is what execs this script in that mode, so
# counting it here is self-referential - the same trap the Boot health section
# documents about grading its own previous run, and verify.timer_enabled about
# asserting its own liveness.
#
# It is self-sustaining rather than merely untidy. A failed unit stays failed
# for the rest of the boot, so one red boot makes this FAIL for ever after,
# which makes --greenboot exit 1, which makes bin/reboot-host.sh and
# bin/reboot-when-staged.sh both refuse - blocking the reboot that is precisely
# what clears the runtime state. Only `systemctl reset-failed` escaped it, by
# hand, on 2026-08-16.
#
# Nothing is lost: whatever made greenboot fail is measured by THIS battery, in
# this same run, and is reported directly. The failed unit adds no information -
# it only carries a verdict past the point where its cause was fixed. At real
# boot time the unit is `activating` rather than `failed`, so this filter is a
# no-op there; it only affects the later gated runs, which is where it bit.
#
# awk rather than `grep -v`: set -uo pipefail is in force and a grep that
# matches nothing exits 1. ${GREENBOOT:+...} leaves skip empty in the full
# battery, where `$1 != ""` matches every real line, so that path is unchanged.
sysfailed=$(systemctl list-units --failed --no-legend --plain 2>/dev/null \
	| awk -v skip="${GREENBOOT:+greenboot-healthcheck.service}" '$1 != skip {print $1}' \
	| paste -sd' ' -)
if [ -z "$sysfailed" ]; then ok host.failed_units "no failed system units"
else bad host.failed_units "failed system units: $sysfailed"; fi

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
	say greenboot "Boot health"
	# Overridable so this section's own branches can be exercised without a
	# reboot. "Armed" is the claim here that fails silently, so being able to
	# test the logic that reports it is worth three variables.
	boot_state="${HOME_SERVER_BOOT_STATE:-/var/lib/home-server/boot-state}"
	gb_etc="${HOME_SERVER_GREENBOOT_ETC:-/etc/greenboot}"
	gb_cfg="${HOME_SERVER_GRUB_CUSTOM:-/boot/grub2/custom.cfg}"
	# THE BINARY, NOT /etc/greenboot, IS WHAT "INSTALLED" MEANS. /etc is
	# merged forward across deployments and can be created by hand, so it
	# survives a rollback to a deployment that has no greenboot in it - and
	# would then report an armed rollback that cannot happen. /usr is part of
	# the deployment, so the binary answers the question honestly.
	gb_bin="${HOME_SERVER_GREENBOOT_BIN:-/usr/libexec/greenboot/greenboot}"

	# The loudest thing here. A red boot means a deployment was rejected, and
	# this mark is also what stops bin/reboot-when-staged.sh rebooting into the
	# same image tonight - so it is cleared by a person, not aged out.
	gb_red=$(sed -n 's/^red_boot_at=//p' "$boot_state" 2>/dev/null | tail -1)
	fact red_boot_at "${gb_red:-}"
	if [ -z "$gb_red" ]; then
		ok greenboot.red_boot "no boot has been rejected"
	else
		bad greenboot.red_boot "greenboot REJECTED a boot at $gb_red - unattended reboots are held; clear red_boot_at in $boot_state once understood"
	fi

	# Hoisted out of the chain below so greenboot.installed reports on both
	# branches. It used to be the first arm of an if/elif, which meant it spoke
	# only when greenboot was missing - and everything downstream of it was
	# skipped, so a host without greenboot produced one WARN and then silence
	# where seven checks should have been.
	if [ -x "$gb_bin" ]; then
		ok greenboot.installed "greenboot is installed"
	else
		warn greenboot.installed "greenboot is not installed - a bad deployment cannot roll itself back"
	fi

	if [ ! -x "$gb_bin" ]; then
		: # nothing further to say; the WARN above is the whole finding
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
			bad greenboot.verdict_present "greenboot ran but recorded no verdict - is the check symlinked into /etc/greenboot/check/?"
		else
			warn greenboot.verdict_present "greenboot has not run since this boot - the next reboot is its first"
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
			bad greenboot.verdict "greenboot recorded no verdict for this boot (last was ${gb_at:-never}) - the check is not running"
		else
			case "$gb_result" in
				green)   ok greenboot.verdict "greenboot verified this boot healthy" ;;
				red)     bad greenboot.verdict "greenboot FAILED this boot's health check" ;;
				timeout) warn greenboot.verdict "greenboot's health check timed out - inconclusive, nothing was rolled back" ;;
				missing) warn greenboot.verdict "greenboot found no checkout to run - nothing was verified this boot" ;;
				*)       warn greenboot.verdict "greenboot recorded an unrecognised verdict '${gb_result:-none}'" ;;
			esac
		fi

		# ARMED IS TWO THINGS, AND EITHER MISSING IS SILENT. The check must be
		# in required.d - wanted.d only logs - AND the GRUB counter must exist,
		# because without the GRUB custom.cfg greenboot arms a boot_counter
		# that nothing counts down. Neither absence shows up anywhere else.
		if   [ -e "$gb_etc/check/required.d/40-home-server.sh" ]; then gb_dir=required
		elif [ -e "$gb_etc/check/wanted.d/40-home-server.sh" ];   then gb_dir=wanted
		else gb_dir=absent
		fi
		gb_grub=no
		[ -f "$gb_cfg" ] && gb_grub=yes

		# THE ORDERING DROP-IN, ASSERTED BY ITS EFFECT RATHER THAN ITS
		# PRESENCE. It was first shipped as a symlink into /var/home-server,
		# where PID 1 cannot read it under SELinux: `systemctl cat` printed it
		# and none of it applied. Checking that the file exists would have
		# passed throughout. Ask systemd what it actually loaded instead.
		if systemctl show greenboot-healthcheck.service -p After --value 2>/dev/null | grep -q 'firewall-stack-ports.service'; then
			ok greenboot.ordering_dropin "greenboot's ordering drop-in is loaded"
		else
			bad greenboot.ordering_dropin "greenboot's ordering drop-in is NOT loaded - the check races the units it asserts"
		fi

		# Enabled is separate from installed, and FCOS ships
		# 99-default-disable.preset - so layering greenboot leaves every one of
		# its units disabled and nothing runs at boot. Silent, and it looks
		# exactly like a host that has never had a bad deployment.
		if [ "$(systemctl is-enabled greenboot-healthcheck.service 2>/dev/null)" = enabled ]; then
			ok greenboot.unit_enabled "greenboot-healthcheck.service is enabled"
		else
			bad greenboot.unit_enabled "greenboot-healthcheck.service is not enabled - no check runs at boot"
		fi

		if [ "$gb_dir" = absent ]; then
			bad greenboot.armed "the home-server check is in neither required.d nor wanted.d - greenboot is not checking this host"
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
			warn greenboot.armed "greenboot is armed but there is only ${depl_count:-?} deployment - nothing to roll back to until one stages"
		elif [ "$gb_dir" = required ] && [ "$gb_grub" = yes ]; then
			ok greenboot.armed "greenboot is armed - a failed check reverts the deployment"
		else
			warn greenboot.armed "greenboot is observe-only (${gb_dir}.d, GRUB counter: ${gb_grub}) - a bad deployment will NOT roll back"
		fi
	fi

	# After the block, not inside it: gb_result is only assigned on one path, and
	# a key that appears and disappears forces a reader to guess which it is.
	fact greenboot_result "${gb_result:-}"

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
	say reboot "Reboot window"

	# Initialised unconditionally: the MOTD below reads it, that block also runs
	# under --greenboot, and `set -u` is on.
	reboot_next=""
	if [ "$(systemctl --user is-enabled home-server-reboot.timer 2>/dev/null)" = enabled ]; then
		ok reboot.timer_enabled "home-server-reboot.timer enabled"
		# Computed HERE rather than in the MOTD block, because that block also
		# runs under --greenboot - as root, at boot, where there is no
		# XDG_RUNTIME_DIR and `systemctl --user` cannot answer at all.
		reboot_next=$(systemctl --user list-timers home-server-reboot.timer \
			--no-legend --no-pager 2>/dev/null | awk 'NR==1 {print $1, $2, $3, $4}')
	else
		bad reboot.timer_enabled "home-server-reboot.timer is not enabled - a staged deployment would never be applied"
	fi

	# A WEEK, not a night. The unit fires five times on a Sunday morning and in
	# the ordinary case refuses on all five, because nothing is staged; what this
	# asserts is that the group ran at all. Possible only since check_timer_run
	# started deriving its staleness threshold from the period it is given.
	check_timer_run reboot.window_run "unattended reboot window" 604800 home-server-reboot.service --user

	# THE MARKER FINALLY EARNING ITS KEEP. bin/reboot-when-staged.sh writes this
	# immediately before rebooting, because afterwards there is no process left
	# to write anything - and until now nothing read it, so "the window applied
	# an update on Sunday" and "the window has not fired since March" still
	# looked identical from this side. It is also the only thing that
	# distinguishes an unattended reboot from a power cut.
	unatt=$(sed -n 's/^unattended_reboot_at=//p' "$boot_state" 2>/dev/null | tail -1)
	if [ -z "$unatt" ]; then
		ok reboot.last_applied "the reboot window has not applied a deployment yet"
	else
		unatt_epoch=$(date -d "$unatt" +%s 2>/dev/null || echo 0)
		boot_epoch=$(( $(date +%s) - uptime_s ))
		# A window rather than an equality: the mark is written seconds before
		# `systemctl reboot` and the boot that follows takes as long as it takes.
		if [ "$unatt_epoch" -le "$boot_epoch" ] && [ "$unatt_epoch" -gt "$(( boot_epoch - 600 ))" ]; then
			ok reboot.last_applied "this boot was applied by the unattended window at $unatt"
		else
			ok reboot.last_applied "the reboot window last applied a deployment at $unatt"
		fi
	fi

	say update "Container updates"

	# The same argument as rpm-ostreed-automatic above: a timer that has stopped
	# firing, or a run that failed, looks exactly like a week with no upstream
	# releases. There is no alerting here yet, so the MOTD is the channel - which
	# means the check has to exist rather than the failure being assumed visible.
	if [ "$(systemctl --user is-enabled podman-auto-update.timer 2>/dev/null)" = enabled ]; then
		ok update.podman_timer "podman-auto-update.timer enabled"
	else
		bad update.podman_timer "podman-auto-update.timer is not enabled - no container ever updates"
	fi
	check_timer_run update.podman_run "container update" 86400 podman-auto-update.service --user

	# Caddy is built here, and `local` policy notices a new image without ever
	# producing one - so if this timer stops, Caddy silently stops updating while
	# every other service carries on.
	if [ "$(systemctl --user is-enabled home-server-caddy-build.timer 2>/dev/null)" = enabled ]; then
		ok update.caddy_build_timer "home-server-caddy-build.timer enabled"
	else
		bad update.caddy_build_timer "home-server-caddy-build.timer is off - Caddy will never be rebuilt"
	fi

	# The dashboard is the second built image, and its timer carries MORE than
	# Caddy's does: this image's content comes from the checkout, so this timer
	# is also the deploy path. Without it a `git pull` that changes
	# apps/dashboard/src/ deploys nothing at all - silently, while every other
	# kind of change in the same commit takes effect on daemon-reload.
	if [ "$(systemctl --user is-enabled home-server-dashboard-build.timer 2>/dev/null)" = enabled ]; then
		ok update.dashboard_build_timer "home-server-dashboard-build.timer enabled"
	else
		bad update.dashboard_build_timer "home-server-dashboard-build.timer is off - the dashboard will never pick up a commit"
	fi

	# Every container that can be auto-updated should be. A unit that lost its
	# policy would simply never appear here again, silently.
	au_count=$(podman auto-update --dry-run 2>/dev/null | grep -cE 'registry|local' || true)
	if [ "${au_count:-0}" -ge 20 ]; then
		ok update.policy_count "$au_count containers carry an auto-update policy"
	else
		bad update.policy_count "only ${au_count:-0} containers carry an auto-update policy, expected 20"
	fi

	# ------------------------------------------------------------------------------
	say backup "Backups"
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
	if [ "$(systemctl --user is-enabled home-server-backup.timer 2>/dev/null)" = enabled ]; then
		ok backup.timer_enabled "home-server-backup.timer enabled"
	else
		bad backup.timer_enabled "home-server-backup.timer is not enabled - config/ is not being backed up"
	fi
	check_timer_run backup.run "backup" 86400 home-server-backup.service --user

	# Same ${HOME:-} guard as line 42. This branch only runs as `core`, where
	# HOME is always set, but an unbound expansion aborts the whole script
	# under `set -u` and that is too sharp an edge to leave lying around.
	backup_state="${HOME:-/root}/.cache/home-server/backup-state"
	# <id> <label> <key> <max-hours> <severity>
	check_backup_age() {
		local id="$1" label="$2" key="$3" max="$4" sev="$5" at age
		at=$(sed -n "s/^${key}=//p" "$backup_state" 2>/dev/null | tail -1)
		fact "backup_$key" "${at:-}"
		if [ -z "$at" ]; then
			# Same argument as check_timer_run: on a host that has just been
			# rebuilt this is true and uninteresting, and a finding nobody can
			# act on is how someone learns to ignore this whole block.
			if [ "$uptime_s" -lt 86400 ]; then
				ok "$id" "no $label recorded yet (up $((uptime_s / 60))m) - not yet due"
			else
				bad "$id" "no $label has EVER been recorded"
			fi
			return
		fi
		age=$(( ( $(date +%s) - $(date -d "$at" +%s) ) / 3600 ))
		if [ "$age" -le "$max" ]; then
			ok "$id" "$label ${age}h ago"
		else
			"$sev" "$id" "the $label is ${age}h old (limit ${max}h)"
		fi
	}
	# The local copy is on the same disk as config/, so it is the weaker of the
	# two: it covers a bad change, not a dead disk. The off-site one is the copy
	# that survives nvme0n1, which is why its ceiling is tight as well.
	check_backup_age backup.local_age           "local backup"    local_at   48 bad
	check_backup_age backup.offsite_age         "off-site backup" offsite_at 72 bad
	# The server's key cannot delete, deliberately - so nothing here prunes the
	# off-site repository and it grows until the workstation runs
	# bin/backup-offsite.sh. Slow, but unbounded if nobody ever does.
	check_backup_age backup.offsite_prune_age   "off-site prune" offsite_pruned_at 720 warn
	# "Cannot delete" is the whole reason the server is allowed to hold a backup
	# credential at all, and it is enforced by an ABSENCE - nothing grants delete
	# outside locks/, so there is no Deny statement to eyeball and a policy that
	# has silently widened looks exactly like one that works. It also lives
	# outside this repository, in Scaleway's bucket and IAM policies, where a
	# console edit or a key rotation can change it with nothing here noticing.
	# backup-server.sh therefore re-proves it nightly and writes this marker only
	# on a confirmed refusal; 48h matches the local ceiling, so one unreachable
	# night is tolerated and a real drift surfaces on the second.
	check_backup_age backup.offsite_delete_denial "off-site delete denial" offsite_policy_ok_at 48 bad
	# The metrics store is captured by its own admin API rather than by the file
	# copy, and that step is deliberately non-fatal - losing metrics history must
	# never abort the run carrying the *arr databases and Caddy's private keys.
	# WARN rather than FAIL for the same reason: a stopped Prometheus would
	# otherwise block the unattended reboot window, and a reboot does not fix it.
	# Without this the step could stop working and nothing would ever say so.
	check_backup_age backup.tsdb_snapshot_age   "metrics snapshot" tsdb_snapshot_at 48 warn

	# ------------------------------------------------------------------------------
	say checkout "Checkout"
	# ------------------------------------------------------------------------------
	# Containers update themselves nightly and the OS stages itself nightly, but
	# the unit definitions only move when a human types `git pull` - so this is
	# the one part of the system with no automation and no feedback. The remote
	# has drifted from git before, and an edit made over ssh is invisible until
	# the next pull refuses with "local changes would be overwritten".
	# DERIVED, not a literal. Every other script here computes its root from
	# BASH_SOURCE; this one hardcoded the path, so it checked "is the checkout
	# at /var/<name> clean" rather than "is the checkout I am part of clean".
	# Those are the same sentence right up until the tree moves, which is
	# exactly when you want the answer to be about the tree that moved.
	repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
	fact checkout_clean "$([ -z "$dirty" ] && echo true || echo false)" bool
	if [ -z "$dirty" ]; then
		ok checkout.clean "checkout is clean"
	else
		bad checkout.clean "LOCAL CHANGES on the server: $(echo "$dirty" | awk '{print $2}' | tr '\n' ' ')"
	fi

	# ls-remote rather than fetch: it writes nothing into .git, so this script
	# stays read-only apart from the MOTD. The cost is that it cannot tell ahead
	# from behind - only that the two differ, which is the thing worth saying.
	local_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
	remote_head=$(git -C "$repo" ls-remote origin HEAD 2>/dev/null | awk '{print $1}')
	if [ -z "$remote_head" ]; then
		note checkout.matches_origin "could not reach origin - not a health problem"
	elif [ "$local_head" = "$remote_head" ]; then
		ok checkout.matches_origin "checkout matches origin"
	else
		warn checkout.matches_origin "checkout is not at origin (local ${local_head:0:7}, origin ${remote_head:0:7})"
	fi

	say containers "Containers"

	userfailed=$(systemctl --user list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
	if [ -z "$userfailed" ]; then ok containers.failed_units "no failed user units"
	else bad containers.failed_units "failed user units: $userfailed"; fi

	running=$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
	fact containers_running "${running:-}" num
	unhealthy=$(podman ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | paste -sd' ' -)
	if [ -z "$unhealthy" ]; then ok containers.healthy "$running containers up, none unhealthy"
	else bad containers.healthy "unhealthy: $unhealthy"; fi

	# duckdns, unpackerr and the pod's infra container define no healthcheck.
	# A check that assumes all of them do reports those three broken for ever.
	for c in jellyfin tdarr-node-01; do
		if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
			if podman exec "$c" nvidia-smi -L 2>/dev/null | grep -q '^GPU '; then
				ok "containers.gpu_${c//-/_}" "$c can see its GPU"
			else
				bad "containers.gpu_${c//-/_}" "$c cannot see a GPU - check the CDI spec"
			fi
		else
			note "containers.gpu_${c//-/_}" "$c is not running, GPU not checked"
		fi
	done

	# --------------------------------------------------------------------------
	# Logs. The policy, and whether it is actually in force.
	# --------------------------------------------------------------------------
	# EVERY CHECK HERE IS WARN OR PASS, NEVER FAIL, and that is a constraint
	# rather than a preference. bin/reboot-host.sh refuses to reboot a host this
	# battery calls unhealthy, so a FAIL here would block reboots over a log
	# directory - and none of these findings is fixed by a reboot or a rollback.
	# It is the same mistake the /boot pin logic above already documents.
	#
	# THE EXPECTED VALUES ARE DECLARED HERE AS WELL AS IN THE DROP-IN, on
	# purpose. A check that reads its expectation out of the file it is checking
	# asserts only that the file parses - the same argument as greenboot's
	# ordering drop-in, which is asserted by its effect rather than its presence.
	say logs "Logs"
	jd_want_max=16G jd_want_retention=90d
	jd_cap_mb=16384 cfg_log_ceiling_mb=500

	# The EFFECT of Storage=persistent, not the setting. Without this directory
	# the journal is tmpfs, nothing survives a reboot, and every other check in
	# this section is measuring something that is about to be thrown away.
	if [ -d /var/log/journal ]; then
		ok logs.persistent "the journal is persistent"
	else
		warn logs.persistent "/var/log/journal does not exist - the journal is tmpfs and a reboot loses all of it"
	fi

	# Ask systemd what it MERGED, not what is on disk. A drop-in can be present
	# and not loaded, and `ls` cannot tell the difference.
	jcfg=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null)
	if [ -z "$jcfg" ]; then
		warn logs.dropin_loaded "could not read the effective journald configuration"
	elif grep -q '10-home-server.conf' <<<"$jcfg"; then
		ok logs.dropin_loaded "the home-server journald drop-in is loaded"
	else
		warn logs.dropin_loaded "no home-server journald drop-in is loaded - retention is whatever the default happens to be"
	fi

	# tail -1 reproduces systemd's own last-wins precedence, so a later-sorting
	# drop-in that overrides ours is caught rather than hidden.
	jval() { sed -n "s/^[[:space:]]*$1=//p" <<<"$jcfg" | tail -1; }
	jd_bad=""
	[ "$(jval SystemMaxUse)"     = "$jd_want_max" ]       || jd_bad="$jd_bad SystemMaxUse=$(jval SystemMaxUse)"
	[ "$(jval MaxRetentionSec)"  = "$jd_want_retention" ] || jd_bad="$jd_bad MaxRetentionSec=$(jval MaxRetentionSec)"
	if [ -z "$jcfg" ]; then
		: # already warned above; do not say the same thing twice
	elif [ -z "$jd_bad" ]; then
		ok logs.dropin_values "journald keeps ${jd_want_retention}, capped at ${jd_want_max}"
	else
		warn logs.dropin_values "journald policy differs from this repo:${jd_bad}"
	fi

	# THE EFFECT CHECK THAT MAKES THE TWO ABOVE MEAN ANYTHING. If usage is over
	# the declared cap then journald is not enforcing what the file says,
	# whatever the file says.
	jd_mb=$(du -sm /var/log/journal 2>/dev/null | awk '{print $1}')
	fact journal_mb "${jd_mb:-}" num
	fact journal_cap_mb "$jd_cap_mb" num
	if [ -z "$jd_mb" ]; then
		warn logs.disk_usage "could not measure /var/log/journal"
	elif [ "$jd_mb" -le "$jd_cap_mb" ]; then
		ok logs.disk_usage "journal is ${jd_mb}M of ${jd_cap_mb}M"
	else
		warn logs.disk_usage "journal is ${jd_mb}M, over the ${jd_cap_mb}M cap - the limit is not being enforced"
	fi

	# Measured rather than declared. head -1 exits early on SIGPIPE, so this
	# reads the front of the journal rather than all of it - 6ms, not seconds.
	jd_oldest=$(journalctl -q -o short-unix --no-pager 2>/dev/null | head -1 | cut -d. -f1)
	if [ -n "${jd_oldest##*[!0-9]*}" ] && [ -n "$jd_oldest" ]; then
		jd_days=$(( ( $(date +%s) - jd_oldest ) / 86400 ))
		fact journal_retention_days "$jd_days" num
		# The interesting case is not "short" on its own - a freshly installed
		# host is legitimately short. It is short WHILE AT THE CAP, which means
		# size is the binding constraint and the stated 90 days is fiction.
		if [ "$jd_days" -lt 30 ] && [ "${jd_mb:-0}" -ge "$jd_cap_mb" ]; then
			warn logs.retention "only ${jd_days}d of journal and it is at the size cap - volume has outgrown the ${jd_want_retention} policy"
		else
			ok logs.retention "${jd_days}d of journal history"
		fi
	else
		fact journal_retention_days "" num
		warn logs.retention "could not read the oldest journal entry"
	fi

	# These are log lines that were LOST. A rate limit doing its job silently is
	# how the one line you needed goes missing, so it has to be counted rather
	# than assumed absent - which is also why the drop-in states the limits.
	sup_raw=$(journalctl -q --no-pager --since=-24h -u systemd-journald -o cat 2>/dev/null | grep '^Suppressed ' || true)
	sup_n=$(sed -n 's/^Suppressed \([0-9]*\) messages.*/\1/p' <<<"$sup_raw" | awk '{s += $1} END {print s + 0}')
	fact journal_suppressed_24h "${sup_n:-0}" num
	if [ "${sup_n:-0}" -eq 0 ]; then
		ok logs.suppressed_24h "journald dropped nothing in 24h"
	else
		warn logs.suppressed_24h "journald dropped ${sup_n} messages in 24h - absence of a log line is no longer evidence"
	fi

	# PROVEN, NOT READ. podman info does not expose healthcheck_events, so the
	# only way to know host/containers/containers.conf is in force is to count
	# the events it is supposed to have stopped - the same argument as the
	# nightly off-site delete-probe.
	#
	# 15 MINUTES, not 60. The window has to be long enough that zero cannot
	# happen by chance and short enough to clear promptly after a change: with
	# gluetun at 5s, most containers at 60s and the Tdarr nodes at 120s, a
	# quarter of an hour is several hundred events if the setting is on. At 60m
	# it was safe but took a full hour to stop reporting events that predated
	# the fix, which reads as "the change did not work".
	#
	# timeout, because `podman events` streams by default and a hung probe in an
	# hourly timer has nothing else bounding it. An inconclusive probe is a WARN,
	# never a pass: unknown is not zero.
	if hc_out=$(timeout 15 podman events --since=15m --until=1s \
			--filter event=health_status --format '{{.Status}}' 2>/dev/null); then
		hc_n=$(grep -c . <<<"$hc_out" || true)
		[ -n "$hc_out" ] || hc_n=0
		fact healthcheck_events_15m "$hc_n" num
		if [ "$hc_n" -eq 0 ] && [ "${running:-0}" -eq 0 ]; then
			# ZERO EVENTS FROM ZERO CONTAINERS PROVES NOTHING. Without this the
			# probe reads PASS on a host where the whole stack is down, which is
			# the reading least likely to be true and most likely to be trusted.
			note logs.healthcheck_events "no containers running - healthcheck_events cannot be proved either way"
		elif [ "$hc_n" -eq 0 ]; then
			ok logs.healthcheck_events "no health_status events from $running containers - healthcheck_events is off"
		else
			warn logs.healthcheck_events "$hc_n health_status events in the last 15 min - healthcheck_events=false is NOT in force, and they are ~47% of journal volume"
		fi
	else
		fact healthcheck_events_15m "" num
		warn logs.healthcheck_events "could not read podman events - cannot prove healthcheck_events is off"
	fi

	# config/ is the one thing here that cannot be rebuilt from git, and it is
	# staged and copied to two restic repositories every night. The backup
	# already excludes these directories, so this is about the NVMe rather than
	# the snapshots - an app that starts looping fills the disk config/ is on.
	cfgroot="${DOCKER_VOLUME_CONFIG:-/var/home-server/config}"
	cfg_log_mb=0 cfg_log_top=""
	if [ -d "$cfgroot" ]; then
		# Process substitution rather than a pipe, so the accumulator survives
		# the loop - same idiom as bin/lint-repo.sh. sort -rn puts the largest
		# first, so the first iteration names the offender.
		while read -r sz path; do
			cfg_log_mb=$(( cfg_log_mb + sz ))
			[ -n "$cfg_log_top" ] || cfg_log_top="${path#"$cfgroot"/} (${sz}M)"
		done < <(find "$cfgroot" -maxdepth 3 -type d \( -name logs -o -name log -o -name Logs \) \
			-print0 2>/dev/null | xargs -0 -r du -sm 2>/dev/null | sort -rn)
		fact config_log_mb "$cfg_log_mb" num
		if [ "$cfg_log_mb" -le "$cfg_log_ceiling_mb" ]; then
			ok logs.config_log_size "app logs under config/ are ${cfg_log_mb}M"
		else
			warn logs.config_log_size "app logs under config/ are ${cfg_log_mb}M, over ${cfg_log_ceiling_mb}M - largest is ${cfg_log_top}"
		fi
	else
		fact config_log_mb "" num
		note logs.config_log_size "no config tree at $cfgroot - not measured"
	fi

	# --------------------------------------------------------------------------
	# Metrics. Is anything recording, and is it recording the truth?
	# --------------------------------------------------------------------------
	# EVERY CHECK HERE IS WARN OR PASS, NEVER FAIL, for exactly the reason the
	# Logs section above gives: bin/reboot-host.sh and bin/reboot-when-staged.sh
	# both refuse to act on a host this battery calls unhealthy, so a FAIL here
	# would let a stopped collector block an OS security update. None of these
	# findings is fixed by a reboot or by a rollback.
	#
	# The host cannot route to a rootless podman bridge, so every query goes in
	# through `podman exec` - the same escape hatch containers.gpu_* uses, and
	# the reason net-metrics needs no published port.
	say metrics "Metrics"

	if [ "$(systemctl --user is-enabled home-server-metrics.timer 2>/dev/null)" = enabled ]; then
		ok metrics.timer_enabled "home-server-metrics.timer enabled"
	else
		warn metrics.timer_enabled "home-server-metrics.timer is not enabled - the host-side series stop and every graph of them freezes"
	fi

	# DELIBERATELY NOT check_timer_run. That helper grades in whole hours -
	# age=$((.../3600)) against stale_h=$((period*2/3600)) - so against a
	# 30-second period it compares a zero-hour age to a zero-hour threshold and
	# passes a collector that stopped 55 minutes ago. Second resolution here,
	# with the same uptime guard the helper uses, because a machine that booted
	# a minute ago has legitimately not collected anything yet.
	m_ok=$(sed -n 's/^last_ok_at=//p' \
		"$HOME/.cache/home-server/metrics-state" 2>/dev/null | tail -1)
	m_age=
	if [ -n "$m_ok" ]; then
		m_epoch=$(date -d "$m_ok" +%s 2>/dev/null)
		[ -z "$m_epoch" ] || m_age=$(( $(date +%s) - m_epoch ))
	fi
	if [ -n "$m_age" ] && [ "$m_age" -le 300 ]; then
		ok metrics.collector_fresh "metrics collected ${m_age}s ago"
	elif [ -n "$m_age" ]; then
		warn metrics.collector_fresh "the last successful collection was ${m_age}s ago, limit 300s - those graphs are showing a gap, not a healthy host"
	elif [ "${uptime_s:-0}" -lt 120 ]; then
		ok metrics.collector_fresh "nothing collected in the ${uptime_s}s since boot - not yet due"
	else
		warn metrics.collector_fresh "the collector has no record of a successful run"
	fi
	fact metrics_last_ok_at "${m_ok:-}"
	fact metrics_collect_age_s "${m_age:-}" num

	# Endpoints that need no URL encoding are chosen deliberately. The
	# label-values API answers "which collectors are running" and the targets
	# API answers "how many are down" without a PromQL matcher, so this section
	# carries no percent-encoded query strings for a later edit to break
	# silently. promq is only for bare metric names.
	promq() {  # <metric name, no braces or matchers> -> first sample value
		podman exec prometheus wget -q -O - \
			"http://127.0.0.1:9090/api/v1/query?query=$1" 2>/dev/null \
			| jq -r '.data.result[0].value[1] // empty' 2>/dev/null
	}

	prom_up=
	if podman exec prometheus wget -q -O /dev/null \
		http://127.0.0.1:9090/-/healthy 2>/dev/null; then
		prom_up=1
		ok metrics.prometheus_up "prometheus is answering"
	else
		warn metrics.prometheus_up "prometheus is not answering /-/healthy - nothing is being recorded"
	fi

	# THE CHECK THIS SECTION EXISTS FOR. A dead exporter does not blank a graph,
	# it freezes it at the last value it managed to scrape - which renders as a
	# flat, healthy-looking line. Nothing else here would notice.
	tgt_json=
	[ -z "$prom_up" ] || tgt_json=$(podman exec prometheus wget -q -O - \
		'http://127.0.0.1:9090/api/v1/targets?state=active' 2>/dev/null)
	tgt_total=$(printf '%s' "$tgt_json" | jq -r '.data.activeTargets|length' 2>/dev/null)
	tgt_down=$(printf '%s' "$tgt_json" \
		| jq -r '[.data.activeTargets[]|select(.health!="up")]|length' 2>/dev/null)
	tgt_names=$(printf '%s' "$tgt_json" \
		| jq -r '[.data.activeTargets[]|select(.health!="up")|.scrapePool]|unique|join(" ")' 2>/dev/null)
	if [ -z "${tgt_total:-}" ]; then
		warn metrics.targets_down "the scrape target list could not be read"
	elif [ "${tgt_down:-0}" -eq 0 ]; then
		ok metrics.targets_down "all $tgt_total scrape targets up"
	else
		warn metrics.targets_down "$tgt_down of $tgt_total scrape targets down ($tgt_names) - those graphs are frozen, not blank"
	fi
	fact metrics_targets_total "${tgt_total:-}" num
	fact metrics_targets_down "${tgt_down:-}" num

	# --------------------------------------------------------------------------
	# The alerting path, which cannot be trusted to report its own failure
	# --------------------------------------------------------------------------
	# EVERY OTHER CHECK IN THIS SCRIPT IS WATCHED BY THE ALERTING CHAIN. This one
	# watches the chain, and it has to live here rather than in a Prometheus rule
	# for the obvious reason: a rule about a broken notifier cannot be delivered
	# by the notifier. status.json and the MOTD are the out-of-band channel, so
	# these three findings are the only warning that alerting has stopped.
	#
	# It is also the exact failure this deployment actually hit. Alertmanager
	# named a password file on the read-only mount, where ExecStartPre= cannot
	# write it - so every container stayed healthy, promtool and amtool both
	# passed, Prometheus discovered the Alertmanager, and every notification
	# failed with a 401 recorded nowhere but Alertmanager's own log.
	rules_n=
	[ -z "$prom_up" ] || rules_n=$(podman exec prometheus wget -q -O - \
		http://127.0.0.1:9090/api/v1/rules 2>/dev/null \
		| jq -r '[.data.groups[].rules[]]|length' 2>/dev/null)
	if [ -z "${rules_n:-}" ]; then
		warn metrics.alert_rules "the alerting rules could not be read"
	elif [ "$rules_n" -gt 0 ]; then
		ok metrics.alert_rules "$rules_n alerting rules loaded"
	else
		warn metrics.alert_rules "no alerting rules are loaded - nothing can fire"
	fi
	fact metrics_alert_rules "${rules_n:-}" num

	am_n=
	[ -z "$prom_up" ] || am_n=$(podman exec prometheus wget -q -O - \
		http://127.0.0.1:9090/api/v1/alertmanagers 2>/dev/null \
		| jq -r '.data.activeAlertmanagers|length' 2>/dev/null)
	if [ -z "${am_n:-}" ]; then
		warn metrics.alertmanager_up "the Alertmanager list could not be read"
	elif [ "$am_n" -gt 0 ]; then
		ok metrics.alertmanager_up "$am_n Alertmanager reachable from prometheus"
	else
		warn metrics.alertmanager_up "prometheus has no Alertmanager - rules evaluate and go nowhere"
	fi

	# Delivery, as opposed to configuration. A rising error counter is the
	# signature of a bridge that is refusing or unreachable, and it is the only
	# place that shows up short of reading the journal.
	notify_err=$(promq 'increase(prometheus_notifications_errors_total[1h])')
	notify_err=${notify_err%%.*}
	if [ -z "${notify_err:-}" ]; then
		note metrics.alert_delivery "notification errors not measured"
	elif [ "$notify_err" -eq 0 ]; then
		ok metrics.alert_delivery "no alert delivery errors in the last hour"
	else
		warn metrics.alert_delivery "$notify_err alert deliveries failed in the last hour - alerts are being evaluated and dropped"
	fi
	fact metrics_notify_errors "${notify_err:-}" num

	# node-exporter's namespace-scoped collectors must stay off. /proc/net is a
	# symlink to self/net, so it resolves in the READER's network namespace and
	# not in the mounted procfs - a bridge-networked node-exporter therefore
	# reports its own container's interfaces while looking exactly like it is
	# reporting the host's. Wrong numbers under the right names, which is the
	# one failure a dashboard cannot show you.
	#
	# Asserted by which collectors are RUNNING, not by which series exist:
	# bin/collect-metrics.py supplies the real node_network_* through the
	# textfile collector, so by name the two are indistinguishable.
	cols=
	[ -z "$prom_up" ] || cols=$(podman exec prometheus wget -q -O - \
		'http://127.0.0.1:9090/api/v1/label/collector/values' 2>/dev/null \
		| jq -r '.data[]?' 2>/dev/null)
	netns_on=$(printf '%s\n' "$cols" \
		| grep -xE 'netdev|netstat|netclass|sockstat|softnet|arp|conntrack|udp_queues' \
		| paste -sd' ' -)
	if [ -z "$cols" ]; then
		warn metrics.node_netns_scope "node-exporter's collector list could not be read"
	elif [ -z "$netns_on" ]; then
		ok metrics.node_netns_scope "node-exporter's namespace-scoped collectors are off"
	else
		warn metrics.node_netns_scope "node-exporter is running namespace-scoped collectors ($netns_on) - those series describe its own container, not the host"
	fi

	# A collector that fails on every scrape emits NOTHING, which looks exactly
	# like a metric nobody configured - no gap in a graph, no error in a
	# dashboard, just a panel that was never built. node_exporter keeps a
	# success flag per collector precisely so this is answerable, and it is worth
	# asking: three of them failed on the first deploy here, one of them
	# filesystem, and the only visible symptom was an empty query.
	failed_cols=$(podman exec prometheus wget -q -O - \
		'http://127.0.0.1:9090/api/v1/query?query=node_scrape_collector_success' 2>/dev/null \
		| jq -r '[.data.result[]|select(.value[1]=="0")|.metric.collector]|sort|join(" ")' 2>/dev/null)
	if [ -z "$prom_up" ]; then
		warn metrics.exporter_collectors "node-exporter's collector results could not be read"
	elif [ -z "$failed_cols" ]; then
		ok metrics.exporter_collectors "every node-exporter collector is succeeding"
	else
		warn metrics.exporter_collectors "node-exporter collectors failing silently: $failed_cols - each emits no series at all, which reads as 'not configured'"
	fi

	# Cardinality is what decides whether this store stays smaller than config/.
	# The first symptom of an unbounded label is the unit being killed at
	# MemoryMax, not a slow dashboard, so it is worth seeing it climb.
	#
	# 4000 IS DERIVED FROM A MEASUREMENT, not picked. Steady state on
	# 2026-08-15, with every source running, is 2896 - node-exporter's own, the
	# collector's ~1050 through the textfile, and Prometheus' self-scrape. That
	# leaves about 38% headroom for the things that legitimately grow - another
	# container, another indexer, another filesystem.
	#
	# READ THE LIVE COUNT, NOT THIS ONE, WHEN RE-DERIVING IT. This check reads
	# head series, which counts every series in the head block whether or not it
	# is still receiving samples; `count({__name__=~".+"})` counts only the live
	# ones. The two agreed to within 3% once the head had compacted.
	#
	# EXPECT A TRANSIENT BREACH AFTER ANY RENAME, for that same reason. A series
	# that stops receiving samples stays in the head block until it is compacted
	# out, roughly two hours, so during that window both names are counted: the
	# rename to upstream container_* names read 3378 against a live 2896.
	series=$(promq prometheus_tsdb_head_series)
	series=${series%%.*}
	if [ -z "$series" ]; then
		warn metrics.series_count "the active series count could not be read"
	elif [ "$series" -le 4000 ]; then
		ok metrics.series_count "$series active series"
	else
		warn metrics.series_count "$series active series, over the 4000 budget - look for a label carrying a path, a title, an id or an address"
	fi
	fact metrics_series "${series:-}" num

	# Retention is two limits, whichever is reached first, and this is the
	# tripwire for neither being enforced. It shares nvme0n1p4 with config/ and
	# /var/backups, so it is the NVMe this protects rather than the graphs.
	tsdbroot="${DOCKER_VOLUME_CONFIG:-/var/home-server/config}/prometheus"
	tsdb_mb=
	[ ! -d "$tsdbroot" ] || tsdb_mb=$(du -sm "$tsdbroot" 2>/dev/null | cut -f1)
	tsdb_ceiling_mb=18432
	if [ -z "$tsdb_mb" ]; then
		note metrics.tsdb_size "no metrics store at $tsdbroot - not measured"
	elif [ "$tsdb_mb" -le "$tsdb_ceiling_mb" ]; then
		ok metrics.tsdb_size "the metrics store is ${tsdb_mb}M"
	else
		warn metrics.tsdb_size "the metrics store is ${tsdb_mb}M, over ${tsdb_ceiling_mb}M - retention is not being enforced"
	fi
	fact metrics_tsdb_mb "${tsdb_mb:-}" num

	# --------------------------------------------------------------------------
	# This script's own liveness - and the one question it must NOT ask.
	# --------------------------------------------------------------------------
	# THERE IS DELIBERATELY NO check_timer_run FOR home-server-verify.service
	# HERE. It was written, it shipped, and it failed on the server within the
	# minute, in a way worth keeping:
	#
	#   - Inside its own unit, ExecMainExitTimestamp is EMPTY - systemd clears it
	#     when the service starts and only sets it on exit. So the check read
	#     "has never run" and raised a FAIL.
	#   - That FAIL made the unit exit 1. The next run then read ExecMainStatus=1
	#     and raised "the last run FAILED". Permanently, having caused it.
	#
	# A self-referential FAIL that also gates bin/reboot-host.sh. This is exactly
	# the trap the Boot health section documents - a check grading its own
	# previous run - and the reasoning that it was somehow different here was
	# simply wrong.
	#
	# A script cannot assert its own liveness: if it is not running nothing
	# evaluates the assertion, and if it is running the answer is trivially yes.
	# THAT is why status.json carries generated_at and lives somewhere a reboot
	# does not wipe - a stopped timer is detectable only from outside, by a
	# reader noticing the document has gone stale.
	#
	# What IS answerable from in here is the question one step earlier: is the
	# timer even armed? That reads systemd's configuration rather than this
	# script's own output, so it has no feedback loop.
	say verify "Self"
	if [ "$(systemctl --user is-enabled home-server-verify.timer 2>/dev/null)" = enabled ]; then
		ok verify.timer_enabled "home-server-verify.timer enabled"
	else
		bad verify.timer_enabled "home-server-verify.timer is not enabled - the MOTD and status.json silently stop being refreshed"
	fi

	if [ -n "$ROUTES" ]; then
		say routes "Public routes"
		# `home` answers 302 to auth.<domain>, like every other protected route.
		# NOTE what that does and does not prove: a 302 from a protected route
		# says DNS, TLS, Caddy's block and the forward_auth to Tinyauth all
		# work, and says NOTHING about the backend, because an unauthenticated
		# request never reaches it. qBittorrent was crash-looping behind a
		# healthy-looking 302 once already. The dashboard's own health check is
		# what covers the container.
		for h in watch request id auth home sonarr radarr prowlarr tdarr torrent ntfy; do
			code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$h.avanserv.com/" 2>/dev/null)
			# ntfy IS THE ONE WHOSE HEALTHY ANSWER IS A REFUSAL, and it has to be
			# in this battery rather than left out: it is the route every alert
			# travels, so if it breaks, the thing that would have told you is the
			# thing that broke. An unauthenticated request to a deny-all instance
			# is answered 403 BY NTFY, which proves DNS, TLS, Caddy's route and
			# the backend all work. Accepting 200 here would be the bug - that
			# would mean anonymous access had been opened.
			case "$h:$code" in
				ntfy:401|ntfy:403) ok "routes.$h" "$h -> $code (refused, as it must be)" ;;
				ntfy:*) bad "routes.$h" "$h -> ${code:-no answer}, expected 401 or 403" ;;
				*:200|*:302|*:307) ok "routes.$h" "$h -> $code" ;;
				*) bad "routes.$h" "$h -> ${code:-no answer}" ;;
			esac
		done
	fi
fi

# ------------------------------------------------------------------------------
# The MOTD. Warnings only when warranted, plus two lines that are always there:
# a one-line summary, and when this last ran.
# ------------------------------------------------------------------------------
motd=/run/motd.d/40-home-server.motd
{
	printf '  \033[1m-- home-server -------------------------------------------------\033[0m\n'
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
		# true when home-server-reboot.timer was armed.
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

# ------------------------------------------------------------------------------
# The machine-readable half
# ------------------------------------------------------------------------------
# AFTER THE MOTD, BEFORE THE EXIT, and both halves of that matter. After,
# because the MOTD is the human channel and must be written even if jq is
# missing. Before, because a FAILING host is the one case a dashboard exists
# for - emitting after `exit 1` would produce a document for healthy hosts only.
#
# NOT UNDER --greenboot. That mode runs as root before the user session exists
# and its exit code decides whether the OS rolls back, so it gets no new failure
# modes: no jq, no sudo mkdir, no writes. Its verdict already has a durable home
# in boot-state, written by the greenboot wrapper. It still records ids into the
# arrays above - keeping one code path is safer than branching it - and simply
# never encodes them.
if [ -z "$GREENBOOT" ]; then
	status_file="${HOME_SERVER_STATUS_FILE:-/var/lib/home-server/status.json}"
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# THE DURABLE RECORD THIS SCRIPT HAS NEVER HAD. Every other automated job
	# here writes a marker that this battery then ages; this one wrote only a
	# MOTD, on tmpfs, which a reboot wipes. status.json lives in /var/lib and
	# carries generated_at, so it IS the marker - no second file needed.
	#
	# Read the previous success BEFORE overwriting it, so a run that FAILs
	# carries the old timestamp forward. Same argument as backup-server.sh:
	# "failing since Tuesday" and "has never once passed" must not look alike.
	verify_ok=$(sed -n 's/.*"verify_last_ok_at": *"\([^"]*\)".*/\1/p' "$status_file" 2>/dev/null | tail -1)
	[ ${#fails[@]} -gt 0 ] || verify_ok="$now"

	fact verify_last_run_at "$now"
	fact verify_last_ok_at  "${verify_ok:-}"
	fact verify_fail_count  "${#fails[@]}" num
	fact verify_warn_count  "${#warns[@]}" num
	fact uptime_s           "${uptime_s:-}" num

	# A DUPLICATE ID IS INVISIBLE FROM THE CONSUMER'S SIDE: two checks sharing a
	# key means a dashboard shows one and silently hides the other, for ever - a
	# check that does nothing, indistinguishable from one that works. Asserted
	# here rather than in bin/lint-repo.sh because an id legitimately appears
	# many times in the SOURCE, once per branch; what must be unique is what a
	# single run emits, and only a run knows that.
	dup_ids=$(printf '%s\n' ${chk_id+"${chk_id[@]}"} | sort | uniq -d | tr '\n' ' ')
	if [ -n "${dup_ids// /}" ]; then
		cur_sect=verify
		bad verify.unique_ids "duplicate check id(s) emitted: ${dup_ids}- a dashboard will hide one of each pair"
	fi

	# NUL-DELIMITED, and that is the whole safety argument: a bash string is
	# NUL-terminated, so it is the one byte a message provably cannot contain.
	# Quotes, backslashes, pipes and embedded newlines all survive and jq
	# escapes them on the way out.
	#
	# Index loops rather than `for x in "${arr[@]}"`: ${#arr[@]} is well-defined
	# on an empty array under `set -u`, so these need no ${arr+...} guard and the
	# body simply never runs.
	_stream_sections() { local i; for ((i = 0; i < ${#sect_id[@]}; i++)); do
		printf '%s\0%s\0' "${sect_id[i]}" "${sect_title[i]}"; done; }
	_stream_checks() { local i; for ((i = 0; i < ${#chk_id[@]}; i++)); do
		printf '%s\0%s\0%s\0%s\0' \
			"${chk_sect[i]}" "${chk_id[i]}" "${chk_status[i]}" "${chk_msg[i]}"; done; }
	_stream_facts() { local i; for ((i = 0; i < ${#fact_k[@]}; i++)); do
		printf '%s\0%s\0%s\0' "${fact_k[i]}" "${fact_t[i]}" "${fact_v[i]}"; done; }

	# .[:-1] drops the empty element split leaves after the final NUL. On an
	# empty stream split gives [""], so .[:-1] gives [] and the zero case needs
	# no special branch.
	j_sections=$(_stream_sections | jq -Rs 'split("\u0000") | .[:-1]
		| [ range(0; length; 2) as $i | { id: .[$i], title: .[$i+1] } ]' 2>/dev/null)
	j_checks=$(_stream_checks | jq -Rs 'split("\u0000") | .[:-1]
		| [ range(0; length; 4) as $i
		    | { section: .[$i], id: .[$i+1], status: .[$i+2], message: .[$i+3] } ]' 2>/dev/null)
	j_facts=$(_stream_facts | jq -Rs 'split("\u0000") | .[:-1]
		| [ range(0; length; 3) as $i
		    | { key: .[$i],
		        value: ( .[$i+2] as $v
		                 | if   $v == ""          then null
		                   elif .[$i+1] == "num"  then ($v | tonumber? // null)
		                   elif .[$i+1] == "bool" then ($v == "true")
		                   else $v end ) } ]
		| from_entries' 2>/dev/null)

	doc=""
	if [ -n "$j_sections" ] && [ -n "$j_checks" ] && [ -n "$j_facts" ]; then
		doc=$(jq -n \
			--arg     generated_at "$now" \
			--arg     host         "$(uname -n 2>/dev/null)" \
			--arg     routes       "${ROUTES:-}" \
			--argjson sections     "$j_sections" \
			--argjson checks       "$j_checks" \
			--argjson facts        "$j_facts" \
			'($checks | map(.status)) as $st
			 | { schema: 1,
			     generated_at: $generated_at,
			     host: $host,
			     mode: { routes: ($routes != "") },
			     summary: {
			       status: (if   ($st | any(. == "fail")) then "fail"
			                elif ($st | any(. == "warn")) then "warn"
			                else "pass" end),
			       pass:  ($st | map(select(. == "pass")) | length),
			       fail:  ($st | map(select(. == "fail")) | length),
			       warn:  ($st | map(select(. == "warn")) | length),
			       note:  ($st | map(select(. == "note")) | length),
			       total: ($st | length) },
			     sections: [ $sections[] as $s
			                 | ($checks | map(select(.section == $s.id))) as $c
			                 | $s + { pass: ($c | map(select(.status == "pass")) | length),
			                          fail: ($c | map(select(.status == "fail")) | length),
			                          warn: ($c | map(select(.status == "warn")) | length),
			                          note: ($c | map(select(.status == "note")) | length) } ],
			     checks: $checks,
			     facts: $facts }' 2>/dev/null)
	fi

	[ -z "$JSON" ] || printf '%s\n' "$doc"

	# A STALE status.json IS HONEST; A TRUNCATED ONE IS NOT. generated_at tells a
	# reader how old the document is, so declining to write anything when jq
	# failed costs nothing - whereas an empty {} would show a healthy host as
	# unknown, or a failing one as fine.
	if [ -n "$doc" ]; then
		priv mkdir -p "$(dirname "$status_file")" >/dev/null 2>&1
		if ! { printf '%s\n' "$doc" | priv tee "$status_file.tmp" >/dev/null 2>&1 \
			&& priv mv "$status_file.tmp" "$status_file" >/dev/null 2>&1; }; then
			# STDERR, NOT warn(), and the reason is circular by nature: the
			# document has already been encoded by this point, so a finding
			# recorded here could only be reported inside the file we just
			# failed to write. The timer runs --quiet, so stderr is what puts
			# this in the journal - the same reasoning that sends --greenboot's
			# FAILs there.
			#
			# Louder than the MOTD's `|| true` above because a silently stale
			# status file is exactly what a dashboard misreads as current.
			printf 'verify-host: could not write %s - any dashboard reading it is seeing stale data\n' \
				"$status_file" >&2
		fi

		# THE SERVED COPY, and it is a copy rather than a mount for a reason
		# that is not obvious.
		#
		# The file above is written through `priv`, i.e. sudo, so it is
		# root-owned inside a var_lib_t directory. container_t may not read
		# var_lib_t, and `:z` cannot rescue it: relabelling on a rootless
		# podman mount is performed by the INVOKING user, and `core` does not
		# own /var/lib/home-server, so chcon fails EPERM. The mount would be
		# accepted and the container would get permission denied.
		#
		# So the same bytes are written a second time, as core, into a small
		# dedicated directory that the dashboard bind-mounts :z,ro. That is the
		# identical shape as node-exporter's textfile drop, which CLAUDE.md
		# already names as the one directory here that may safely take a label.
		#
		# Best-effort, and deliberately so: this is a convenience for one
		# container, and the canonical file above is what everything else -
		# bin/collect-metrics.py included - reads. A dashboard showing a stale
		# document says so on its own, because generated_at travels inside it.
		served_dir="${DOCKER_VOLUME_CACHE:-/var/home-server/cache}/dashboard"
		if mkdir -p "$served_dir" 2>/dev/null; then
			if printf '%s\n' "$doc" >"$served_dir/status.json.tmp" 2>/dev/null; then
				mv "$served_dir/status.json.tmp" "$served_dir/status.json" 2>/dev/null || :
			fi
			rm -f "$served_dir/status.json.tmp" 2>/dev/null || :
		fi
	fi
fi

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
