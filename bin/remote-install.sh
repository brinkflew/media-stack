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
# After this runs, the old system exists only in the disk image. The primary
# copy is /mnt/media/nvme0n1.img.zst on sda - a different physical device this
# install does not touch - which makes it restorable from the live session with
# no network and no workstation. MEDIA_STACK_DISK_IMAGE names a second copy, if
# one was taken. This script reports which of them it can actually see, at the
# moment that matters, rather than naming a path and hoping.
# ==============================================================================

set -euo pipefail

TARGET_IP="${MEDIA_STACK_LIVE_IP:-192.168.0.100}"
INSTALL_DEV="/dev/nvme0n1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${MEDIA_STACK_WORK:-$HOME/.cache/media-stack/fcos}"
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mremote-install: %s\033[0m\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2029  # "$@" is the CALLER's command, so expanding it
# here is the point of the wrapper, not an accident.
live() { ssh "${SSHOPTS[@]}" "core@$TARGET_IP" "$@"; }

# ------------------------------------------------------------------------------
# Confirm we are talking to the live environment, not the old system
# ------------------------------------------------------------------------------
# Running coreos-installer against a mounted, running root would fail - but
# checking is cheaper than finding out, and a mistyped IP could point anywhere.
say "confirming the target"
live true 2>/dev/null || die "cannot reach core@$TARGET_IP - run bin/remote-kexec.sh first"

# Match on VARIANT_ID, not ID. Fedora CoreOS reports ID=fedora with
# VARIANT_ID=coreos; there is no ID=fedora-coreos, which is what this checked
# for until it refused to install from a perfectly good live environment. The
# rehearsal could not have caught it, because the rehearsal stops one script
# earlier - every check in this file is first exercised on the real run.
variant=$(live 'grep -m1 ^VARIANT_ID= /etc/os-release | cut -d= -f2' || true)
[ "$variant" = "coreos" ] || die "core@$TARGET_IP reports VARIANT_ID='$variant', not coreos.
  Refusing to install onto something that is not a Fedora CoreOS live environment."
live 'test -f /run/ostree-live' \
  || die "this does not look like a LIVE boot - refusing.
  Installing from an installed system would overwrite the disk it is running from."
echo "  live Fedora CoreOS confirmed (VARIANT_ID=$variant, /run/ostree-live present)"

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
#
# Look on the media disk FIRST and from in here, because that is the copy that
# matters: sda survives this install, so an image sitting on it can be written
# straight back to nvme0n1 from this same live session. A copy on the
# workstation is a fallback, not the plan - it means pushing 73GB back over the
# network to a machine with no console.
say "locating the rollback image"
live 'sudo vgchange -ay >/dev/null 2>&1 || true
      sudo mkdir -p /var/tmp/media
      findmnt -rn /var/tmp/media >/dev/null 2>&1 ||
        sudo mount -o ro /dev/mapper/vg_xfs_media-xfs_db /var/tmp/media 2>/dev/null || true' || true
onbox=$(live 'stat -c %s /var/tmp/media/nvme0n1.img.zst 2>/dev/null || echo 0' || echo 0)

IMAGE="${MEDIA_STACK_DISK_IMAGE:-$HOME/backups/nvme0n1.img.zst}"
offbox=0
[ -f "$IMAGE" ] && offbox=$(stat -c %s "$IMAGE")

if [ "${onbox:-0}" -gt 1000000000 ]; then
  echo "  on the media disk: $onbox bytes, mounted read-only here"
  IMAGE_STATUS="on sda, restorable from this session without a network:
                  /mnt/media/nvme0n1.img.zst  ($((onbox / 1000000000)) GB)"
  [ "$offbox" -gt 1000000000 ] && IMAGE_STATUS="$IMAGE_STATUS
                  second copy on the workstation: $IMAGE"
elif [ "$offbox" -gt 1000000000 ]; then
  echo "  NOT on the media disk - only on the workstation"
  IMAGE_STATUS="workstation only: $IMAGE ($((offbox / 1000000000)) GB).
                  Restoring means pushing it back over the network."
else
  echo "  WARNING: no image on the media disk, and none at $IMAGE"
  IMAGE_STATUS="*** NONE FOUND - you have no rollback ***"
fi

cat <<EOF

  ------------------------------------------------------------------------
   This writes Fedora CoreOS over $INSTALL_DEV.

   DESTROYED    /var/media-stack (checkout, .env, config/)
                /home/avanserv   (including the server's age key)
                /var/lib/docker  (images, volumes, the Minecraft world)
                the Fedora 37 install itself

   SURVIVES     /mnt/media - 7.3TB XFS on LVM on sda, a different disk

   RECOVERY     only the disk image, restored from this live environment.
                There is no console on this machine.
                $IMAGE_STATUS
  ------------------------------------------------------------------------

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

  Then, still Fedora CoreOS rather than uCore - the rebase is next. Ignition has
  already masked zincati, so --bypass-driver is not needed. It takes TWO
  rebases: the first cannot be signature-verified, because stock FCOS has no
  ghcr.io/ublue-os scope in its policy.json - that arrives with uCore itself.
      ssh core@$TARGET_IP 'sudo systemd-run --unit=ucore-rebase --collect \\
        rpm-ostree rebase \\
        ostree-unverified-registry:ghcr.io/ublue-os/ucore:stable-nvidia-lts'
      ssh core@$TARGET_IP 'journalctl -u ucore-rebase -f'   # ~1.3 GB
      ssh core@$TARGET_IP 'sudo systemctl reboot'

  Then again, signed, now that uCore's policy and cosign keys are in place:
      ssh core@$TARGET_IP 'sudo systemd-run --unit=ucore-signed --collect \\
        rpm-ostree rebase \\
        ostree-image-signed:docker://ghcr.io/ublue-os/ucore:stable-nvidia-lts'
      ssh core@$TARGET_IP 'sudo systemctl reboot'

  -lts is the NVIDIA DRIVER branch, not an LTS kernel. Do not "correct" it.

  There is no nvidia-cdi.service any more - uCore ships NVIDIA's own
  nvidia-cdi-refresh.path, which regenerates /run/cdi on a driver change.

  Then continue at host/RUNBOOK.md, "Restore" - starting with the age key,
  without which nothing else works.

EOF
