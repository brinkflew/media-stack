#!/usr/bin/env bash
# ==============================================================================
# Phase 2 - write uCore to the disk. THIS IS THE IRREVERSIBLE ONE.
# ------------------------------------------------------------------------------
# Run only after bin/remote-kexec.sh has put the machine into the live
# environment and you have confirmed it is reachable there.
#
# It is a separate script rather than a flag on the other one on purpose. The
# boundary between "recoverable by pressing the power button" and "recoverable
# only from a disk image" deserves to be a separate act, typed deliberately.
#
# After this runs, the old system exists only in the disk image - wherever
# MEDIA_STACK_DISK_IMAGE points. It is 73GB and usually on external media, so
# have that drive plugged in before you start.
# ==============================================================================

set -euo pipefail

TARGET_IP="${MEDIA_STACK_LIVE_IP:-192.168.0.100}"
INSTALL_DEV="/dev/nvme0n1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${MEDIA_STACK_WORK:-$HOME/.cache/media-stack/fcos}"
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mremote-install: %s\033[0m\n' "$*" >&2; exit 1; }
live() { ssh "${SSHOPTS[@]}" "core@$TARGET_IP" "$@"; }

# ------------------------------------------------------------------------------
# Confirm we are talking to the live environment, not the old system
# ------------------------------------------------------------------------------
# Running coreos-installer against a mounted, running root would fail - but
# checking is cheaper than finding out, and a mistyped IP could point anywhere.
say "confirming the target"
live true 2>/dev/null || die "cannot reach core@$TARGET_IP - run bin/remote-kexec.sh first"

os=$(live 'grep -m1 ^ID= /etc/os-release | cut -d= -f2')
[ "$os" = "fedora-coreos" ] || die "core@$TARGET_IP is running '$os', not fedora-coreos.
  Refusing to install onto something that is not the live environment."
live 'test -f /run/ostree-live' \
  || die "this does not look like a LIVE boot - refusing.
  Installing from an installed system would overwrite the disk it is running from."
echo "  live Fedora CoreOS confirmed"

# ------------------------------------------------------------------------------
# Confirm the disks, because the wrong device here is unrecoverable
# ------------------------------------------------------------------------------
say "disks as the live environment sees them"
live 'lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID -d' | sed 's/^/  /'
echo
live "test -b $INSTALL_DEV" || die "$INSTALL_DEV does not exist in the live environment"

# sda carries the 7.3TB library on LVM. It is a different physical device and
# nothing here writes to it - but verify rather than trust, because this is the
# one mistake with no recovery at all.
sda_fs=$(live 'lsblk -no FSTYPE /dev/sda1 2>/dev/null | head -1' || true)
[ "$sda_fs" = "LVM2_member" ] \
  || die "/dev/sda1 reports '$sda_fs', expected LVM2_member.
  The media disk is not where it should be. Stop and look before installing."
echo "  /dev/sda1 is still the LVM member holding the library - untouched by this"

media_uuid=$(live 'lsblk -no UUID /dev/mapper/vg_xfs_media-xfs_db 2>/dev/null || true')
if [ -n "$media_uuid" ]; then
  [ "$media_uuid" = "fce53d5f-0849-40dd-81aa-ba21819c7eeb" ] \
    && echo "  media volume UUID matches mnt-media.mount" \
    || echo "  WARNING: media UUID is $media_uuid, but ucore.bu mounts
           fce53d5f-0849-40dd-81aa-ba21819c7eeb. Fix the mount unit or the
           stack will start with an empty library."
else
  echo "  NOTE: LVM volume not activated in the live environment (normal).
        The installed system activates it via lvm2-monitor."
fi

# ------------------------------------------------------------------------------
# Ship the Ignition config
# ------------------------------------------------------------------------------
say "building and shipping ucore.ign"
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < "$REPO/host/butane/ucore.bu" > "$WORK/ucore.ign"
python3 -c "import json; json.load(open('$WORK/ucore.ign'))" || die "ucore.ign is not valid JSON"
grep -q REPLACE_WITH "$REPO/host/butane/ucore.bu" && die "ucore.bu still has a placeholder in it"
scp "${SSHOPTS[@]}" -q "$WORK/ucore.ign" "core@$TARGET_IP:/home/core/ucore.ign"
echo "  $(wc -c < "$WORK/ucore.ign") bytes"

# ------------------------------------------------------------------------------
# The point of no return
# ------------------------------------------------------------------------------
# Report the rollback's actual state in the confirmation banner rather than
# naming a path and hoping. This is the last moment at which "the image is on a
# drive in a drawer" is cheap to discover.
IMAGE="${MEDIA_STACK_DISK_IMAGE:-$HOME/backups/nvme0n1.img.zst}"
if [ -f "$IMAGE" ] && [ "$(stat -c %s "$IMAGE")" -gt 1000000000 ]; then
  IMAGE_STATUS="present: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
else
  IMAGE_STATUS="*** NOT FOUND at $IMAGE - you have no rollback ***"
fi

cat <<EOF

  ────────────────────────────────────────────────────────────────────────
   This writes Fedora CoreOS over $INSTALL_DEV.

   DESTROYED    /var/media-stack (checkout, .env, config/)
                /home/avanserv   (including the server's age key)
                /var/lib/docker  (images, volumes, the Minecraft world)
                the Fedora 37 install itself

   SURVIVES     /mnt/media - 7.3TB XFS on LVM on sda, a different disk

   RECOVERY     only the disk image, restored from this live environment.
                There is no console on this machine.
                $IMAGE_STATUS
  ────────────────────────────────────────────────────────────────────────

EOF
read -r -p "  Type 'install uCore' to proceed: " reply
[ "$reply" = "install uCore" ] || die "aborted - nothing was written"

say "installing"
# No --image-url: the live environment carries the OS image, so this needs no
# network. That is deliberate - it is the same reason the rootfs was baked into
# the initrd rather than fetched.
ssh -t "${SSHOPTS[@]}" "core@$TARGET_IP" \
  "sudo coreos-installer install $INSTALL_DEV --ignition-file /home/core/ucore.ign"

say "rebooting into the installed system"
ssh "${SSHOPTS[@]}" "core@$TARGET_IP" 'sudo systemctl reboot' || true

cat <<EOF

  The machine is rebooting into Fedora CoreOS with the Ignition config applied.

  Its SSH host key has changed:
      ssh-keygen -R $TARGET_IP && ssh-keygen -R home.avanserv.com

  Then, still Fedora CoreOS rather than uCore - the rebase is next:
      ssh avanserv@$TARGET_IP 'sudo rpm-ostree rebase \\
        ostree-unverified-registry:ghcr.io/ublue-os/ucore:stable-nvidia && sudo systemctl reboot'

  nvidia-cdi.service FAILS on this first boot and that is expected - plain FCOS
  has no nvidia-ctk. It succeeds after the rebase. Do not chase it.

  Then continue at host/RUNBOOK.md, "Restore" - starting with the age key,
  without which nothing else works.

EOF
