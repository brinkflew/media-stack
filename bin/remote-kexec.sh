#!/usr/bin/env bash
# ==============================================================================
# Phase 1 - boot the server into a live Fedora CoreOS, over the network
# ------------------------------------------------------------------------------
# RUN THIS YOURSELF, from the workstation. It needs sudo on the server, and the
# password prompt has to reach your terminal.
#
# THIS DOES NOT TOUCH THE DISK. It loads a live FCOS into RAM and kexecs into
# it. If the machine does not come back, press the power button: Fedora 37 boots
# from nvme0n1 exactly as it was. That is what makes this step rehearsable, and
# rehearsing it is the whole point - this machine has no BMC, so if the real
# migration is the first time you find out whether kexec works on this board,
# you find out with no console and a wiped disk.
#
#   ./bin/remote-kexec.sh            # rehearsal or the real thing; identical
#   ./bin/remote-install.sh          # phase 2, destructive, separate on purpose
#
# Nothing is fetched at boot. The rootfs is concatenated onto the initramfs and
# the Ignition config is embedded in it, so a network that comes up late - or
# not at all - cannot strand the machine. FCOS needs 4 GiB of RAM to run that
# way and this box has 15.
# ==============================================================================

set -euo pipefail

STREAM="stable"
HOST="${MEDIA_STACK_HOST:-home.local}"          # the LAN address, NOT the hairpin
TARGET_IP="192.168.0.100"
GATEWAY="192.168.0.1"
NETMASK="255.255.255.0"
DNS="192.168.0.1"
MAC="4c:ed:fb:3f:97:11"
WORK="${MEDIA_STACK_WORK:-$HOME/.cache/media-stack/fcos}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mremote-kexec: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
# Every one of these is a refusal, not a warning. The cost of continuing past a
# failed check here is a machine you cannot reach and cannot see.
say "preflight"

ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true 2>/dev/null \
  || die "$HOST is not reachable. Use the LAN address - the router's port forward
  points at a fixed IP and is exactly what this migration can break."
echo "  $HOST reachable"

command -v podman >/dev/null || die "podman is needed to run butane and coreos-installer"

# A backup older than the change you are about to make is not a backup. config/
# lives on the disk this wipes, so "recent" means minutes, not days.
if [ -d "${RESTIC_REPOSITORY:-$HOME/backups/media-stack}" ]; then
  export PATH="$HOME/.local/bin:$PATH"
  export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-$HOME/backups/media-stack}"
  export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/media-stack.pw}"
  last=$(restic snapshots --json 2>/dev/null | python3 -c "
import sys, json, datetime
s = json.load(sys.stdin)
if not s: raise SystemExit(1)
t = max(x['time'][:19] for x in s)
age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(t).replace(tzinfo=datetime.timezone.utc)
print(int(age.total_seconds() // 60))" 2>/dev/null) || last=""
  if [ -n "$last" ]; then
    if [ "$last" -gt 120 ]; then
      echo "  WARNING: newest restic snapshot is ${last} minutes old"
      echo "           run ./bin/backup-config.sh first unless this is a rehearsal"
    else
      echo "  restic snapshot ${last} minutes old"
    fi
  fi
fi

# The image is 73GB and usually lives on external media rather than this laptop.
# Point MEDIA_STACK_DISK_IMAGE at it, and have the drive plugged in before the
# real run - a rollback you have to go and find is not a rollback.
IMAGE="${MEDIA_STACK_DISK_IMAGE:-$HOME/backups/nvme0n1.img.zst}"
EXPECT_BYTES=250059350016      # the full size of nvme0n1, from the dd that made it

if [ -f "$IMAGE" ]; then
  echo "  disk image: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
else
  cat <<EOF
  NOTE: no disk image at
          $IMAGE
        Fine for a rehearsal, which cannot damage anything. NOT fine for the
        real run: it is the only rollback and, with no console on this machine,
        the only diagnosis. Set MEDIA_STACK_DISK_IMAGE if it lives elsewhere.
EOF
fi

# ------------------------------------------------------------------------------
# Artifacts
# ------------------------------------------------------------------------------
say "resolving the $STREAM stream"
mkdir -p "$WORK"
meta="$WORK/stream.json"
curl -fsSL "https://builds.coreos.fedoraproject.org/streams/${STREAM}.json" -o "$meta"

eval "$(python3 - "$meta" <<'PY'
import sys, json
a = json.load(open(sys.argv[1]))['architectures']['x86_64']['artifacts']['metal']
print("RELEASE=%s" % a['release'])
for part in ('kernel', 'initramfs', 'rootfs'):
    i = a['formats']['pxe'][part]
    print("%s_URL=%s" % (part.upper(), i['location']))
    print("%s_SHA=%s" % (part.upper(), i['sha256']))
PY
)"
echo "  release $RELEASE"

fetch() {  # url sha dest
  if [ -f "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ]; then
    echo "  $(basename "$3") cached"
    return
  fi
  echo "  fetching $(basename "$3")"
  curl -fL# "$1" -o "$3"
  # Checked, not trusted. This is the kernel the machine will run with no
  # console to tell you it did not.
  [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ] || die "checksum mismatch on $3"
}
fetch "$KERNEL_URL"    "$KERNEL_SHA"    "$WORK/kernel"
fetch "$INITRAMFS_URL" "$INITRAMFS_SHA" "$WORK/initramfs.img"
fetch "$ROOTFS_URL"    "$ROOTFS_SHA"    "$WORK/rootfs.img"

# ------------------------------------------------------------------------------
# Build the initrd
# ------------------------------------------------------------------------------
say "embedding the live Ignition config"
podman run --rm -i quay.io/coreos/butane:release --pretty --strict \
  < "$REPO/host/butane/live.bu" > "$WORK/live.ign"
python3 -c "import json,sys; json.load(open('$WORK/live.ign'))" || die "live.ign is not valid JSON"

rm -f "$WORK/custom-initramfs.img"
podman run --rm -v "$WORK:/w:z" quay.io/coreos/coreos-installer:release \
  pxe customize --live-ignition /w/live.ign -o /w/custom-initramfs.img /w/initramfs.img
echo "  custom initramfs: $(du -h "$WORK/custom-initramfs.img" | cut -f1)"

# FCOS documents loading the rootfs as a SECOND initrd. A bootloader does that
# by concatenating them in memory, so for kexec - which takes one file - `cat`
# is the same thing. The alternative, coreos.live.rootfs_url, would make the
# boot depend on a working network at the worst possible moment.
say "concatenating the rootfs"
cat "$WORK/custom-initramfs.img" "$WORK/rootfs.img" > "$WORK/combined.img"
echo "  combined initrd: $(du -h "$WORK/combined.img" | cut -f1)"

# ------------------------------------------------------------------------------
# Stage on the server
# ------------------------------------------------------------------------------
say "staging on $HOST"
ssh "$HOST" 'mkdir -p /var/tmp/fcos && df -h /var/tmp --output=avail | tail -1 | xargs echo "  /var/tmp free:"'
scp -q "$WORK/kernel" "$WORK/combined.img" "$HOST:/var/tmp/fcos/"
ssh "$HOST" 'ls -lh /var/tmp/fcos | tail -2 | sed "s/^/  /"'

# ------------------------------------------------------------------------------
# kexec
# ------------------------------------------------------------------------------
# ifname= pins the interface to the MAC, so the address does not depend on FCOS
# choosing the same predictable name Fedora 37 did. ip= is dracut's, applied in
# the initramfs - earlier and more reliably than a NetworkManager keyfile.
KARGS="ignition.firstboot ignition.platform.id=metal"
KARGS="$KARGS ifname=nic0:${MAC}"
KARGS="$KARGS ip=${TARGET_IP}::${GATEWAY}:${NETMASK}:home:nic0:none"
KARGS="$KARGS nameserver=${DNS}"
KARGS="$KARGS console=tty0 console=ttyS0,115200n8"

say "ready to kexec"
cat <<EOF

  target      $HOST  ->  live FCOS $RELEASE, in RAM
  disk        NOT TOUCHED. Recovery is the power button.
  address     $TARGET_IP (static, pinned to $MAC)
  after this  ssh core@$TARGET_IP

  The stack goes down now and stays down until you either install or power-cycle.

EOF
read -r -p "  Type 'kexec' to proceed: " reply
[ "$reply" = "kexec" ] || die "aborted"

say "stopping the stack"
ssh "$HOST" 'cd /var/media-stack && docker compose down' || echo "  (compose down failed; continuing)"

say "loading the kernel"
ssh -t "$HOST" "sudo kexec -l /var/tmp/fcos/kernel \
  --initrd=/var/tmp/fcos/combined.img \
  --command-line=\"$KARGS\""

say "kexec'ing"
# `systemctl kexec`, not `kexec -e`: it runs a clean shutdown first, so if this
# does end up needing a power cycle, the filesystems were unmounted properly and
# Fedora 37 comes back without a recovery pass.
ssh -t "$HOST" 'sudo systemctl kexec' || true   # the connection dies mid-command; expected

say "waiting for the live environment"
echo "  polling $TARGET_IP:22 - if this does not answer within ~5 minutes,"
echo "  power-cycle the machine and Fedora 37 will boot back from disk."
for i in $(seq 1 60); do
  sleep 5
  if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null "core@$TARGET_IP" true 2>/dev/null; then
    say "live environment is up"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "core@$TARGET_IP" \
      'echo "  $(grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d \")"
       echo "  address: $(ip -4 -o addr show scope global | awk "{print \$4}" | tr "\n" " ")"
       echo "  disks:"; lsblk -o NAME,SIZE,FSTYPE,LABEL -d | sed "s/^/    /"'
    cat <<EOF

  Rehearsing?  Power-cycle now. Fedora 37 boots back from nvme0n1 untouched.
  For real?    ./bin/remote-install.sh

EOF
    exit 0
  fi
  printf '.'
done

die "no answer after 5 minutes.
  Power-cycle the machine - the disk was never written, so Fedora 37 boots back.
  Then check: kexec support on this firmware, and whether the NIC came up."
