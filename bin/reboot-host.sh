#!/usr/bin/env bash
# ==============================================================================
# Apply a staged deployment and reboot, attended
# ------------------------------------------------------------------------------
# RUNS ON THE WORKSTATION, and it has to: the waiting cannot happen on the
# machine that is rebooting.
#
# This is the one genuinely dangerous operation here. The host has no console and
# no BMC, so a deployment that boots but breaks sshd is a car journey, and there
# is no greenboot yet to roll one back automatically. The procedure was in
# host/RUNBOOK.md as ten commands to type in order; this is those commands, with
# the two mistakes that have actually been made built in as code rather than as
# warnings someone has to remember.
#
# MISTAKE ONE: `ostree admin pin 0`. Index 0 is the STAGED deployment whenever
# one exists, and pinning it fails outright with "Cannot pin staged deployment".
# The booted index has to be derived.
#
# MISTAKE TWO: leaving the pin in place. /boot holds exactly two kernels in
# 350 MB and cannot be grown - nvme0n1p4 is XFS, which no tool can shrink. A pin
# on the booted deployment is free until you reboot; after that, if the new
# deployment carries a different initramfs, the pin is holding a second full
# slot. A firmware bump alone is enough: on 2026-08-14 a rebase that changed no
# kernel package took /boot from 171 MB free to 26 MB. Unpinning is not tidying,
# it is what lets the NEXT update write its kernel at all.
#
# On failure it STOPS with the pin still in place, because that pin is the
# rollback. Read the output, then `sudo rpm-ostree rollback --reboot`.
#
# Usage:
#   bin/reboot-host.sh             pre-flight, confirm, reboot, verify, unpin
#   bin/reboot-host.sh --dry-run   pre-flight only, change nothing
# ==============================================================================

set -uo pipefail

HOST="${MEDIA_STACK_HOST:-home.local}"
BOOT_MIN_MB=160
WAIT_MAX=600
# How long the stack gets to become healthy after it answers ssh. Generous on
# purpose: the cost of waiting is minutes, the cost of declaring a good boot bad
# is an unnecessary rollback.
VERIFY_MAX=600
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[31mreboot-host: %s\033[0m\n' "$*" >&2; exit 1; }
sshq() { ssh -o ConnectTimeout=10 "$HOST" "$@"; }

# ------------------------------------------------------------------------------
say "Pre-flight on $HOST"
# ------------------------------------------------------------------------------
sshq true 2>/dev/null || die "cannot reach $HOST"

# The whole battery, not a subset. If the host is unhealthy NOW, a reboot turns
# one problem into two and you will not know which caused which.
if sshq '/var/media-stack/bin/verify-host.sh --quiet'; then
	ok "verify-host passes"
else
	sshq '/var/media-stack/bin/verify-host.sh' 2>&1 | sed 's/^/  /'
	die "the host is not healthy - fix that before rebooting into a new deployment"
fi

boot_free=$(sshq "df -Pm /boot | awk 'NR==2 {print \$4}'")
if [ "${boot_free:-0}" -ge "$BOOT_MIN_MB" ]; then
	ok "/boot ${boot_free}M free"
else
	die "/boot has only ${boot_free}M free - unpin and 'rpm-ostree cleanup -r' first"
fi

# Nothing mid-encode. A transcode killed halfway leaves a partial file in the
# Tdarr cache and a job that has to be redone; not fatal, but free to avoid.
enc=$(sshq 'nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader,nounits' | tr -d ' ' | tr '\n' '+')
if [ "$(echo "${enc%+}" | tr '+' ' ' | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}')" -eq 0 ]; then
	ok "encoder idle - nothing mid-transcode"
else
	bad "encoder is busy (${enc%+}) - a transcode will be killed"
fi

staged=$(sshq "rpm-ostree status --json | jq -r '.deployments[] | select(.staged) | .version' 2>/dev/null")
booted=$(sshq "rpm-ostree status --json | jq -r '.deployments[] | select(.booted) | .version' 2>/dev/null")
if [ -z "$staged" ]; then
	printf '\n  booted %s, and NOTHING IS STAGED.\n' "$booted"
	printf '  A reboot would come back on the same deployment.\n'
else
	printf '\n  booted  %s\n  staged  %s\n' "$booted" "$staged"
fi

if [ -n "$DRY" ]; then
	# The index is derived here too, so a dry run proves the derivation works
	# against the current deployment list rather than only claiming it would.
	idx=$(sshq "rpm-ostree status --json | jq '[.deployments[]] | map(.booted) | index(true)'")
	printf '\n  booted deployment is index %s (this is what would be pinned)\n' "$idx"
	printf '\n\033[1mdry run - nothing was changed\033[0m\n'
	exit 0
fi

# ------------------------------------------------------------------------------
say "Confirm"
# ------------------------------------------------------------------------------
cat <<EOF

  This reboots $HOST. It has no console and no BMC, so if it does not come
  back you are driving to it. There is no greenboot yet: nothing will roll a
  bad deployment back on its own.

  Do this on a day you could physically reach the machine.

EOF
read -r -p "  Type 'reboot' to proceed: " reply
[ "$reply" = "reboot" ] || die "aborted"

# ------------------------------------------------------------------------------
say "Pinning the booted deployment"
# ------------------------------------------------------------------------------
# NOT index 0. When something is staged, index 0 IS the staged deployment.
idx=$(sshq "rpm-ostree status --json | jq '[.deployments[]] | map(.booted) | index(true)'")
[ -n "$idx" ] && [ "$idx" != "null" ] || die "could not determine the booted deployment index"
sshq "sudo ostree admin pin $idx" || die "could not pin index $idx"
ok "pinned index $idx ($booted) - this is the rollback"

# ------------------------------------------------------------------------------
say "Rebooting"
# ------------------------------------------------------------------------------
# The connection dies with the machine, so a non-zero exit here is expected.
sshq 'sudo systemctl reboot' 2>/dev/null || true

started=$(date +%s)
printf '  waiting for %s to come back' "$HOST"
while :; do
	sleep 5
	elapsed=$(( $(date +%s) - started ))
	if [ "$elapsed" -gt "$WAIT_MAX" ]; then
		printf '\n'
		die "no answer after ${WAIT_MAX}s. The pin is still in place. If you can
  reach a console: rpm-ostree rollback --reboot. Otherwise this is the
  car journey the procedure warns about."
	fi
	# Not just a ping. The box answered ICMP and completed TCP handshakes for the
	# entire time it was wedged in the 470-health-check incident, while no
	# userspace process could be scheduled - so the test has to be a real session.
	if ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; then
		printf '\n'
		ok "back after ${elapsed}s"
		break
	fi
	printf '.'
done

# ------------------------------------------------------------------------------
say "Verifying the new deployment"
# ------------------------------------------------------------------------------
# POLL, do not sleep once and judge. Eighteen containers come up in dependency
# order, every unit with a healthcheck carries Notify=healthy so its start blocks
# until the check passes, and gluetun has to build a tunnel before the three pod
# members can follow it. A single 60s sleep would report a perfectly good boot as
# a failure - and this script's failure path deliberately leaves a pin behind and
# tells you to roll back, which is an expensive thing to get wrong.
#
# media-stack-verify.timer also has OnBootSec=10min for the same reason.
verify_out=""
verified=""
started=$(date +%s)
printf '  waiting for the stack to settle'
while [ $(( $(date +%s) - started )) -lt "$VERIFY_MAX" ]; do
	sleep 20
	if verify_out=$(sshq '/var/media-stack/bin/verify-host.sh' 2>&1); then
		verified=1
		break
	fi
	printf '.'
done
printf '\n'
echo "$verify_out" | sed 's/^/  /'
if [ -n "$verified" ]; then
	ok "the new deployment is healthy after $(( $(date +%s) - started ))s"
else
	cat <<EOF

  VERIFICATION FAILED, and the pin has deliberately been left in place.

  Roll back with:
      ssh $HOST 'sudo rpm-ostree rollback --reboot'

  Then re-run bin/verify-host.sh. Do not unpin until you are back on a
  deployment you trust.
EOF
	exit 1
fi

# ------------------------------------------------------------------------------
say "Unpinning"
# ------------------------------------------------------------------------------
# This is the step that gets skipped, and skipping it is what fills /boot.
pin=$(sshq "rpm-ostree status --json | jq '[.deployments[]] | map(.pinned) | index(true)'")
if [ -n "$pin" ] && [ "$pin" != "null" ]; then
	sshq "sudo ostree admin pin $pin --unpin" || die "could not unpin index $pin"
	sshq 'sudo rpm-ostree cleanup -r' || die "cleanup failed"
	ok "unpinned and cleaned up"
else
	ok "nothing pinned"
fi

after=$(sshq "df -Pm /boot | awk 'NR==2 {print \$4}'")
printf '\n  /boot %sM free (was %sM before the reboot)\n' "$after" "$boot_free"
[ "${after:-0}" -ge "$BOOT_MIN_MB" ] || bad "/boot is below ${BOOT_MIN_MB}M - the next update cannot write its kernel"

printf '\n\033[32mdone\033[0m\n'
