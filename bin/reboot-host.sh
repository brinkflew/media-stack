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

HOST="${HOME_SERVER_HOST:-home.local}"
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
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[31mreboot-host: %s\033[0m\n' "$*" >&2; exit 1; }
# -n matters: without it ssh reads and forwards stdin, so every pre-flight call
# would eat the confirmation before `read` below ever sees it. Nothing here pipes
# data INTO the server, so closing stdin costs nothing and makes the script
# usable non-interactively.
sshq() { ssh -n -o ConnectTimeout=10 "$HOST" "$@"; }

# ------------------------------------------------------------------------------
say "Pre-flight on $HOST"
# ------------------------------------------------------------------------------
sshq true 2>/dev/null || die "cannot reach $HOST"

# GATE ON --greenboot, REPORT THE WHOLE BATTERY. This used to `die` on the full
# battery, on the reasoning that a reboot turns one problem into two - which is
# right about the problems a reboot can turn into two, and wrong about the rest.
# The full battery also covers containers, the backup and the checkout, none of
# which a reboot affects either way, and it covers findings that ONLY a reboot
# can clear. On 2026-08-17 both kinds were present at once: greenboot.verdict was
# red from a rejected boot, clearable only by booting again, and
# backup.offsite_prune_age was a workstation job that had never run. Between them
# they made this script refuse to start - so the remedy for the first finding was
# blocked by the first finding. Same shape as the two traps verify-host.sh
# documents, one layer up, and the argument at the post-reboot gate below had
# already been made and simply never applied here.
#
# So --greenboot is the refusal, exactly as at line 203 and in
# bin/reboot-when-staged.sh, and the full battery is printed for the operator to
# weigh at the typed confirmation. The gates that follow - /boot, the encoder,
# the backup state - are unchanged and still refuse on their own.
if sshq '/var/home-server/bin/verify-host.sh --greenboot' >/dev/null 2>&1; then
	ok "verify-host --greenboot passes"
else
	sshq '/var/home-server/bin/verify-host.sh --greenboot' 2>&1 | sed 's/^/  /' || true
	die "the host fails its own boot health check - a new deployment would be judged against this"
fi

# Run it rather than reading status.json, which the hourly timer leaves up to an
# hour stale - and this is the one moment where a stale answer is worst.
#
# CAPTURED ONCE, not run twice. The obvious spelling asks --quiet for the status
# and then re-runs for the output, which is two full batteries - and since
# deploy.image_digest each one now makes a registry call, so the pre-flight a
# human is waiting on got measurably slower. Take the status and the text from
# the same run.
if battery=$(sshq '/var/home-server/bin/verify-host.sh' 2>&1); then
	ok "the full battery is clean too"
else
	warn "the full battery reports findings this reboot does NOT gate on -"
	warn "read them before confirming; a reboot clears some and none of the rest:"
	printf '%s\n' "$battery" | sed 's/^/  /'
fi

# THE SLOT IS ONLY NEEDED IF A KERNEL HAS TO BE WRITTEN, and that is decided by
# whether the next deployment is STAGED or already PENDING. Finalization at
# shutdown is what writes a /boot entry: a staged deployment needs room for one,
# a pending deployment already has one, and a host with nothing waiting writes
# nothing at all. Gating all three on 160M free refuses exactly the reboot that
# reclaims the space - on 2026-08-18 /boot sat at 26M precisely because a pending
# deployment was holding the second slot, and the reboot that would have freed it
# is the one this gate would have blocked.
boot_free=$(sshq "df -Pm /boot | awk 'NR==2 {print \$4}'")
next_staged=$(sshq "rpm-ostree status --json | jq -r '.deployments[0] | select(.booted | not) | select(.staged) | .version // empty' 2>/dev/null")
if [ "${boot_free:-0}" -ge "$BOOT_MIN_MB" ]; then
	ok "/boot ${boot_free}M free"
elif [ -z "$next_staged" ]; then
	warn "/boot has only ${boot_free}M free, but nothing staged needs a new kernel written -"
	warn "this reboot writes no boot entry. 'rpm-ostree cleanup -r' after it reclaims the slot."
else
	die "/boot has only ${boot_free}M free and $next_staged is STAGED - finalizing it at
  shutdown needs a slot. Unpin and 'rpm-ostree cleanup -r' first."
fi

# WHAT WILL ACTUALLY BE SELECTED, asked before the typed confirmation rather than
# discovered afterwards. See greenboot.boot_target in bin/verify-host.sh: a red
# boot leaves GRUB armed to take the fallback, and it stays armed across every
# repair until the machine boots green once.
grub_counter=$(sshq "sudo -n grub2-editenv /boot/grub2/grubenv list 2>/dev/null | sed -n 's/^boot_counter=//p' | tail -1")
if [ -n "$grub_counter" ]; then
	warn "GRUB is armed to boot the FALLBACK (boot_counter=$grub_counter) - this reboot would"
	warn "ROLL BACK rather than apply anything. Clear it first:"
	warn "  ssh $HOST 'sudo /var/home-server/bin/clear-red-boot.sh'"
fi

# Nothing mid-encode. A transcode killed halfway leaves a partial file in the
# Tdarr cache and a job that has to be redone; not fatal, but free to avoid.
enc=$(sshq 'nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader,nounits' | tr -d ' ' | tr '\n' '+')
if [ "$(echo "${enc%+}" | tr '+' ' ' | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}')" -eq 0 ]; then
	ok "encoder idle - nothing mid-transcode"
else
	bad "encoder is busy (${enc%+}) - a transcode will be killed"
fi

# Nobody mid-film. The encoder check above cannot answer this: a DirectPlay
# session opens no encode session, so it reads 0% while somebody is watching.
#
# WARN RATHER THAN REFUSE, which is this script's whole difference from
# bin/reboot-when-staged.sh - a person is reading this and can decide that the
# household is asleep or that the stream is their own. Unattended, the same
# condition refuses twice before giving way.
watchers=$(sshq '/var/home-server/bin/jellyfin-watching.sh' 2>/dev/null)
case "${watchers:-x}" in
	0)             ok "nobody is watching Jellyfin" ;;
	''|*[!0-9]*)   warn "could not tell whether anyone is watching Jellyfin" ;;
	*)             bad "$watchers Jellyfin session(s) playing - the stream will be cut" ;;
esac

# Index 0, not select(.staged) - see the note at the /boot gate above and the
# long one at next_dep in bin/verify-host.sh. Written the obvious way this said
# "NOTHING IS STAGED. A reboot would come back on the same deployment" about a
# pending deployment that was finalized and ready, i.e. it argued against the
# exact reboot that was needed.
staged=$(sshq "rpm-ostree status --json | jq -r '.deployments[0] | select(.booted | not) | .version // empty' 2>/dev/null")
booted=$(sshq "rpm-ostree status --json | jq -r '.deployments[] | select(.booted) | .version' 2>/dev/null")
if [ -z "$staged" ]; then
	printf '\n  booted %s, and NOTHING IS WAITING TO BOOT.\n' "$booted"
	printf '  A reboot would come back on the same deployment.\n'
elif [ -z "$next_staged" ]; then
	printf '\n  booted   %s\n  pending  %s - already applied, waiting only for this reboot\n' \
		"$booted" "$staged"
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
# ASK THE HOST, rather than state a fact that ages. This line used to say "there
# is no greenboot yet", which was true when it was written and is the kind of
# claim that quietly stops being true. greenboot is a safety net only when BOTH
# halves are present - the check in required.d, and the GRUB counter in
# custom.cfg - and either can go missing without anything else noticing.
if sshq 'test -x /usr/libexec/greenboot/greenboot &&
         test -e /etc/greenboot/check/required.d/40-home-server.sh &&
         test -f /boot/grub2/custom.cfg' >/dev/null 2>&1; then
	rollback_note="greenboot is ARMED: a deployment that fails its health check rolls
  itself back. That is a net, not a guarantee - verify anyway."
else
	rollback_note="greenboot is NOT armed: nothing will roll a bad deployment back
  on its own."
fi

cat <<EOF

  This reboots $HOST. It has no console and no BMC, so if it does not come
  back you are driving to it. $rollback_note

  The pre-flight above hard-refused only on the boot-relevant checks. Anything
  it printed as WARN is yours to weigh here - this is where you accept it.

  Do this on a day you could physically reach the machine.

EOF
read -r -p "  Type 'reboot' to proceed: " reply
[ "$reply" = "reboot" ] || die "aborted"

# ------------------------------------------------------------------------------
say "Pinning the booted deployment"
# ------------------------------------------------------------------------------
# NOT index 0. When something is staged, index 0 IS the staged deployment.
idx=$(sshq "rpm-ostree status --json | jq '[.deployments[]] | map(.booted) | index(true)'")
if [ -z "$idx" ] || [ "$idx" = "null" ]; then
	die "could not determine the booted deployment index"
fi
sshq "sudo ostree admin pin $idx" || die "could not pin index $idx"

# WHAT THIS REBOOT IS SUPPOSED TO END UP ON, captured before it happens because
# afterwards there is nothing left to compare against. Index 0 is what GRUB
# selects by default; the check after the reboot asks whether that is what we
# actually got. Without it this script verifies HEALTH and never IDENTITY, and a
# silent rollback is perfectly healthy - which is how 2026-08-18 produced two
# PASS lines and no OS update.
intended=$(sshq "rpm-ostree status --json | jq -r '.deployments[0].checksum'")
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
	if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; then
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
# home-server-verify.timer also has OnBootSec=10min for the same reason.
# GATE ON --greenboot, NOT ON THE WHOLE BATTERY. The question this step asks is
# "did this deployment boot correctly", and only the host-level checks answer it.
# The full battery also covers containers, the backup and the checkout, none of
# which a rollback would fix - so gating on it means an expired object-storage
# credential, or a Tdarr node that is slow to start, recommends reverting a
# perfectly good OS update.
#
# That is not hypothetical: the first real run of this script hit exactly that,
# twice. Once on /boot free space, which the pin ITSELF had caused, and once on
# a failed backup unit whose credentials had nothing to do with the reboot.
#
# --greenboot is already defined for this exact distinction, and its own comment
# in verify-host.sh says why: "a slow Tdarr start must never be able to" roll a
# deployment back. The full battery is still printed below, for information.
verified=""
started=$(date +%s)
printf '  waiting for the host to settle'
while [ $(( $(date +%s) - started )) -lt "$VERIFY_MAX" ]; do
	sleep 20
	if sshq '/var/home-server/bin/verify-host.sh --greenboot' >/dev/null 2>&1; then
		verified=1
		break
	fi
	printf '.'
done
printf '\n'
if [ -n "$verified" ]; then
	ok "host-level checks pass after $(( $(date +%s) - started ))s"

	# DID WE BOOT WHAT WE MEANT TO? Health and identity are different questions
	# and only the first was ever asked. A GRUB fallback produces a completely
	# healthy host running the deployment you were trying to move off, so every
	# check above passes and the reboot reads as a success. On 2026-08-18 it did
	# exactly that, and the update went unapplied for the rest of the day.
	#
	# REPORTED, NOT TREATED AS A FAILED VERIFICATION, and the difference matters.
	# The failure path below leaves the pin in place because the pin is the
	# rollback - correct when the deployment might be bad. Here the deployment is
	# fine and simply was not selected, so leaving a pin would hold a third /boot
	# slot on a partition that has room for two, which is the very condition that
	# makes this whole class of failure worse. Unpin, clean up, and say plainly
	# what to do next.
	now_csum=$(sshq "rpm-ostree status --json | jq -r '.deployments[] | select(.booted) | .checksum'")
	if [ -n "$intended" ] && [ -n "$now_csum" ] && [ "$intended" != "$now_csum" ]; then
		bad "BOOTED THE WRONG DEPLOYMENT - wanted ${intended:0:12}, got ${now_csum:0:12}"
		cat <<EOF

  GRUB selected the FALLBACK entry rather than the default. That happens when
  boot_counter is set and boot_success is 0 in /boot/grub2/grubenv, which a red
  boot leaves behind and only a GREEN boot clears - so a rejected boot weeks ago
  still redirects the next reboot, whenever it happens.

  This boot has just cleared it. The deployment you wanted is finalized, has its
  /boot entry, and is what index 0 now selects, so simply run this again:

    ssh $HOST 'sudo /var/home-server/bin/clear-red-boot.sh'   # if still armed
    $0

  Nothing is broken and nothing needs rolling back - the host is healthy, it is
  merely running the deployment you were trying to move off.

EOF
	else
		ok "booted the intended deployment (${now_csum:0:12})"
	fi

	# Informational, and deliberately not a gate. Anything failing here is worth
	# reading and is not a reason to roll the OS back.
	say "Full battery (not a gate)"
	sshq '/var/home-server/bin/verify-host.sh' 2>&1 | sed 's/^/  /' || true
else
	sshq '/var/home-server/bin/verify-host.sh --quiet' >/dev/null 2>&1 || true
	sshq '/var/home-server/bin/verify-host.sh' 2>&1 | sed 's/^/  /' || true
	cat <<EOF

  THE HOST-LEVEL CHECKS DID NOT PASS, and the pin has deliberately been left
  in place. The pin is the rollback.

  Read the battery above first. These checks are host-level only - the
  network, the deployment, /boot, the mount, the GPU and CDI, firewalld,
  lingering and cgroup delegation - so a failure here really is about the
  deployment you just booted into, not about a container or a backup.

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
