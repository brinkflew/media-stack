# Stage 2 — migrating the host to uCore

**This runs over the network. No monitor, no keyboard, no USB stick.** The machine has no BMC, so
there is also no console to watch it on — which is why the procedure is shaped the way it is.

**The install is irreversible.** `coreos-installer` rewrites `nvme0n1`'s partition table, and there
is no undo beyond the disk image taken in step 2. Everything below is ordered so that each step's
prerequisites are already true; the failure mode of improvising the order is discovering at step 12
that something you needed was on the disk you wiped at step 6.

## The shape of it

The risk is split in two, at the point of no return:

| | What it does | If it goes wrong |
|---|---|---|
| **`bin/remote-kexec.sh`** | boots a live Fedora CoreOS **into RAM**. The disk is never touched. | **press the power button.** Fedora 37 boots back from `nvme0n1` exactly as it was |
| **`bin/remote-install.sh`** | writes uCore over `nvme0n1` | restore the disk image, which needs the live environment — so get there first |

Because phase 1 cannot damage anything, **rehearse it** (step 5). That is the only step whose
behaviour on this specific board is unknown, and rehearsing it costs one 15-minute window.

Everything the live environment needs is baked into the initrd it boots from — the Ignition config
travels as a `data:` URI and the root filesystem is concatenated onto the initramfs — so **nothing
is fetched at boot**. A network that comes up late, or not at all, cannot strand the machine.

**Use `home.local` throughout, never `home`.** `ssh home` goes out to the WAN and back in through the
router's `9122 → 22` forward, which points at a fixed internal address. Pinning that address is
step 0 of the Ignition config, but until the new system is up, the forward is exactly what a
migration can break. `home.local` is a direct LAN route and does not care.

**Add a second alias for the live environment before you start.** The same address will present
three different host keys during this — Fedora 37, then the live image, then uCore — and each swap
trips `REMOTE HOST IDENTIFICATION HAS CHANGED`. Clearing `known_hosts` each time works, but doing it
repeatedly is how you teach yourself to click through that warning, which is the one warning worth
reading. Give the live environment an alias that never writes to `known_hosts` instead, and leave
`home.local`'s entry alone:

```
Host home-live
    HostName            192.168.0.100
    User                core
    StrictHostKeyChecking no
    UserKnownHostsFile  /dev/null
    LogLevel            ERROR
```

The tradeoff is real — that alias has no MITM protection — but it is scoped to one LAN address you
are actively reinstalling, and the alternative desensitises you on every host.

---

## What the install destroys

`nvme0n1` is wiped in full. On it today:

| Path | What goes | Recovered from |
|---|---|---|
| `/var/media-stack` | the checkout, `.env`, and `config/` (6.3 GB) | git + restic (step 1) |
| `/home/avanserv` | **the server's age private key**, and `sops`/`age` in `~/.local/bin` | your password manager |
| `/var/lib/docker` | every image and 24 volumes, **including the Minecraft world** | nothing — accepted |
| `/` (btrfs) | the Fedora 37 install itself | the disk image (step 2) |

`/mnt/media` **survives**. It is XFS on LVM (`vg_xfs_media/xfs_db`) on `sda`, a different physical
device, and nothing in this procedure writes to it. Verify that claim in step 6 rather than trusting
it — a mistyped install target is the one error with no recovery.

The XDG directories in `/home/avanserv` are empty; there is no personal data to rescue.

---

## Pre-install

### 1. Take a fresh backup — immediately before, not the day before

```bash
cd ~/repos/brinkflew/media-stack && ./bin/backup-config.sh
```

Anything changed between the last backup and the install — a new indexer, another passkey, a
watched episode — exists only on the disk about to be wiped. The run is a few seconds once warm.

Confirm it worked before continuing:

```bash
export RESTIC_REPOSITORY=~/backups/media-stack RESTIC_PASSWORD_FILE=~/.config/restic/media-stack.pw
restic snapshots            # newest should be minutes old
restic check                # no errors
```

### 2. Image the disk

**Run it on the server, detached, writing to the media disk** — not as a pipe from a laptop. Done
this way it takes about seven minutes; done as `ssh dd | zstd` it took over an hour and died at
43 GB when a lid closed, with nothing resumable. The network was the entire cost. `systemd-run`
outlives the SSH session, and the server does not go to sleep.

```bash
ssh home.local 'cd /var/media-stack && docker compose down && sync'

ssh -t home.local 'sudo systemd-run --unit=diskimage --collect \
  /bin/sh -c "dd if=/dev/nvme0n1 bs=4M | zstd -T0 > /mnt/media/nvme0n1.img.zst"'
```

**The output goes to `/mnt/media` on purpose.** It is a different physical device. Writing the image
onto `nvme0n1` would mean the disk changes while it is being read, and the image would contain a
growing partial copy of itself — a backup that restores to nonsense.

Watch it, disconnect freely, come back later:

```bash
ssh home.local 'systemctl status diskimage --no-pager | head -4; ls -lh /mnt/media/nvme0n1.img.zst'
```

**Leave the image on `/mnt/media` — that is where it does the most good, not a staging area to be
emptied.** `sda` is untouched by the install, so a copy sitting there can be written straight back to
`nvme0n1` from the live session, at disk speed, with no network in the path. Moving it to the
workstation and deleting the original converts the cheapest possible rollback into a 73 GB upload
to a machine you cannot see. There is 6.9 TB free; the space was never the constraint.

When the unit has exited, bring the stack back up until the real run:

```bash
ssh home.local 'cd /var/media-stack && docker compose up -d'
```

A **second** copy on the workstation is still worth taking, because the on-box one does not survive
`sda` failing or an install aimed at the wrong device. `rsync -P` resumes, so a dropped laptop costs
seconds rather than the whole run:

```bash
export MEDIA_STACK_DISK_IMAGE=/mnt/e/nvme0n1.img.zst              # external drive; see below
rsync -P home.local:/mnt/media/nvme0n1.img.zst "$MEDIA_STACK_DISK_IMAGE"
```

**73 GB probably does not fit on the workstation, and `df` will lie to you about it.** Under WSL,
`df` inside Linux reports the ext4 disk's own free space, but that disk is a file on the Windows
volume — so it can show hundreds of gigabytes free while the Windows drive underneath has none, and
the copy fails partway. Check the Windows volume, not the Linux one.

External media is the normal answer. Tell the tooling where it went:

```bash
export MEDIA_STACK_DISK_IMAGE=/mnt/e/nvme0n1.img.zst    # wherever it actually is
```

Verify the copy rather than assuming it, because a transfer that runs out of space truncates
quietly and the result still looks like a file:

```bash
stat -c %s "$MEDIA_STACK_DISK_IMAGE"                    # 73579900029
zstd -dc "$MEDIA_STACK_DISK_IMAGE" | wc -c              # 250059350016 - the whole device
```

`bin/remote-install.sh` reports which copies it can actually see, on the media disk and on the
workstation, in the banner at the point of no return — so a drive that is not plugged in is
discovered there rather than after.

Taken with the stack stopped and after `sync`, so the btrfs filesystem inside is **crash-consistent**
— restoring it is equivalent to recovering from a power cut, which btrfs handles. It is not a clean
snapshot, and it does not need to be.

**Budget 75 GB, not the 32 GB that is actually in use.** `dd` reads all 250 GB of the device, and
free space on btrfs is *not* zeroed — it still holds whatever was written there before, which
compresses no better than real data. Measured on this machine: 250,059,350,016 bytes in, 73.6 GB
out.

It takes about **seven minutes** at 590 MB/s, because it runs on the server against a local NVMe.
Piped over SSH from a laptop the same job took over an hour and did not finish — the network, not
the disk, was the whole cost.

`dd` prints nothing until it finishes; `sudo kill -USR1 $(pgrep -f "^dd if=/dev/nvme0n1")` makes it
log progress to the journal.

`--collect` removes the unit as soon as it exits, so `systemctl status diskimage` reporting
**"could not be found" means it finished, not that it failed.** The journal is where the answer is,
and the line to look for is the byte count — it must equal the whole device:

```bash
ssh home.local 'journalctl -u diskimage --no-pager | tail -5'
#   250059350016 bytes (250 GB, 233 GiB) copied ...   <- the full device
#   diskimage.service: Deactivated successfully       <- exit 0
```

**Then verify the archive**, because a truncated zstd stream is not obvious from the file size:

```bash
ssh home.local 'zstd -dc /mnt/media/nvme0n1.img.zst | wc -c'    # must be 250059350016
```

**Do not start the stack until the unit exits.** Writing to the disk mid-read produces an image that
looks complete and restores to a corrupted filesystem — the worst possible failure for the one
artifact that exists to rescue you.

### 3. Confirm you can still get in afterwards

Both of these are **already saved** — this is a check, not a task, and it is the check that matters
most. Without the age key there is no `.env`, and without `.env` nothing starts.

- age private key (server's copy of `~/.config/sops/age/keys.txt`)
- restic repository password

The workstation's own age key can decrypt the secrets too, so you are not locked out if the server's
copy is lost — but restoring it is the documented path.

### 4. Nothing to build

There is no USB stick. `bin/remote-kexec.sh` resolves the current Fedora CoreOS release from the
stream metadata, downloads the kernel, initramfs and rootfs, **verifies their SHA-256**, embeds
`host/butane/live.bu` into the initramfs and concatenates the rootfs onto it. All of that happens on
the workstation and is checked before anything is sent.

---

## Rehearsal

### 5. Boot the live environment, then power-cycle back

The one step whose behaviour on this board is unknown, and the one that costs nothing to test.

```bash
./bin/remote-kexec.sh
```

It stops the stack, loads the kernel, and `systemctl kexec`s into it — a clean shutdown first, so
the filesystems are unmounted properly. Then it polls until the live environment answers.

When it reports success:

```bash
ssh home-live 'cat /etc/os-release | head -2; ip -4 -o addr show scope global'
ssh home-live 'lsblk -o NAME,SIZE,FSTYPE,LABEL -d'
```

Expect **Fedora CoreOS 44**, the address **192.168.0.100/24**, and both disks present with
`nvme0n1` untouched.

**Then power-cycle the machine.** Fedora 37 boots back from disk, because nothing wrote to it.
Confirm:

```bash
ssh home.local 'uptime; cd /var/media-stack && docker compose ps -q | wc -l'   # 17
```

If it does **not** come back within five minutes, power-cycle anyway — that is the whole safety
property. What you have then learned is that `kexec` or the NIC does not work here, at the cost of a
reboot rather than a wiped disk, and the fallback below is the route.

---

## Install

### 6. Get into the live environment

```bash
./bin/backup-config.sh        # again — the rehearsal window may have changed things
./bin/remote-kexec.sh
```

### 7. Check the disks from inside it

```bash
ssh home-live 'lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID'
```

Expect `nvme0n1` at 232.9 G and `sda` at 7.3 T carrying an `LVM2_member` partition. **If `sda` is
anything other than the LVM member, stop.** `bin/remote-install.sh` re-checks both of these and
refuses to run otherwise, but look yourself — it is the one error with no recovery.

### 8. Install

```bash
./bin/remote-install.sh
```

It confirms it is talking to a live boot (not an installed system), verifies `sda`, checks the media
volume's UUID against `mnt-media.mount`, ships `ucore.ign`, and requires you to type
`install uCore`. Then `coreos-installer install /dev/nvme0n1` and a reboot.

### 9. Rebase and reconnect

The host key has changed:

```bash
ssh-keygen -R 192.168.0.100 && ssh-keygen -R home.avanserv.com
```

**Ignition masks Zincati, so `--bypass-driver` is no longer needed.** Stock FCOS delegates all
updates to Zincati, and `rpm-ostree` refuses to act while a driver owns them:

```
error: Updates and deployments are driven by Zincati (zincati.service)
```

Zincati also tracks the *FCOS* stream, so leaving it enabled points an auto-updater at the image you
are deliberately rebasing away from. `host/butane/ucore.bu` masks it and
`bootc-fetch-apply-updates.timer`, leaving `rpm-ostreed-automatic.timer` as the only armed updater —
three are installed and exactly one may be, or they race for the two kernel slots in `/boot`.

**This takes TWO rebases, and the order is not optional.** The first cannot be signature-verified:
stock FCOS's `/etc/containers/policy.json` has no `ghcr.io/ublue-os` scope — that arrives with
uCore's own `/usr/etc`, and `/etc` is only merged when the new deployment is created. So the policy
in force during the first pull is FCOS's, whose `docker` catch-all is `insecureAcceptAnything`.
Shipping the ublue key through Ignition to close that one-time gap would be worse: it becomes a
permanent `/etc` override that ostree preserves for ever, so a key rotation would pin you to a dead
key and every update afterwards would fail silently.

```bash
# 1. unverified, because there is not yet a policy to verify against
ssh core@192.168.0.100 'sudo systemd-run --unit=ucore-rebase --collect \
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/ucore:stable-nvidia-lts'
ssh core@192.168.0.100 'journalctl -u ucore-rebase -f'     # ~1.3 GB to pull
ssh core@192.168.0.100 'sudo systemctl reboot'

# 2. uCore's policy.json and cosign keys are now in place - rebase again, signed
ssh core@192.168.0.100 'sudo podman image trust show | grep ublue'   # sigstoreSigned, NOT the catch-all
ssh core@192.168.0.100 'sudo systemd-run --unit=ucore-signed --collect \
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/ucore:stable-nvidia-lts'
ssh core@192.168.0.100 'sudo systemctl reboot'
```

**`-lts` is the NVIDIA driver branch, not an LTS kernel** — the 580 production branch rather than
610, with an identical kernel either way. Do not "correct" it to `stable-nvidia`.

A bad signature is the safe failure: the rebase exits non-zero and **creates no deployment**, so
there is nothing to undo. The dangerous one is the opposite — a typo'd scope falls through to the
`docker` catch-all and verification silently passes, which is what the `image trust show` line
above is for.

`systemd-run` rather than a foreground command for the same reason the disk image used it: it
outlives the SSH session, so a dropped laptop does not abort a multi-gigabyte pull.

**`nvidia-cdi.service` fails on the first boot and that is expected** — plain FCOS has no
`nvidia-ctk`. It succeeds after the rebase. Do not chase it.

---

## Fallback: the console path

Use this if the rehearsal shows `kexec` does not work here, or if phase 2 fails and leaves the
machine unbootable. It needs a monitor, a keyboard and two USB sticks.

1. Write the **Fedora CoreOS live ISO** to a USB stick.
2. `podman run --rm -i quay.io/coreos/butane:release --pretty --strict < host/butane/ucore.bu > ucore.ign`
   and put it on a second stick.
3. Boot the ISO, `lsblk` and confirm the disks as in step 7.
4. `sudo coreos-installer install /dev/nvme0n1 --ignition-file ucore.ign` — **not `sda`**.
5. Rebase as in step 9.

Everything from *Restore* onwards is identical either way.

---

## Restore

Strict order. Each step depends on the one before it. Steps 10–13 run **on the server**, reached as
`ssh core@192.168.0.100` — the address is now pinned statically by the Ignition config, so it is
the same one as before.

### 10. The repository

```bash
sudo mkdir -p /var/media-stack && sudo chown core:core /var/media-stack
git clone https://github.com/brinkflew/media-stack /var/media-stack
```

Ignition symlinked `~/.config/containers/systemd/{common,torrent,media,infra}` into this directory,
so those links dangle until now and **no unit generates before this step**.

### 11. The age key — nothing works before this

```bash
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
# paste the private key from your password manager
chmod 600 ~/.config/sops/age/keys.txt
```

Get this wrong and `render-env.sh` fails loudly, which is the good outcome. The bad outcome is
skipping it and hand-writing a `.env`: quadlets expand an undefined `${VAR}` to an **empty string
silently**, with none of Compose's `${VAR:?err}` loudness, so the stack comes up subtly broken.

### 12. sops and age

```bash
mkdir -p ~/.local/bin
curl -sSLo ~/.local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
chmod +x ~/.local/bin/sops
curl -sSL https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz \
  | tar xz -C /tmp && install -m755 /tmp/age/age /tmp/age/age-keygen ~/.local/bin/
```

`/usr` is immutable here, so `~/.local/bin` is the right place — it is also what `render-env.sh`
puts on `PATH` itself.

### 13. Render the environment

```bash
cd /var/media-stack && ./bin/render-env.sh      # expect "wrote /var/media-stack/.env"
```

### 14. Restore `config/`

**As `core`, not with sudo.** restic recreates files owned by the user running it, and uid 1000
is precisely what rootless Podman maps container root to — which is what makes `PUID=0` in the
quadlets correct. Restoring as root produces a config tree no container can write.

From the workstation:

```bash
export RESTIC_REPOSITORY=~/backups/media-stack RESTIC_PASSWORD_FILE=~/.config/restic/media-stack.pw
restic restore latest --target /tmp/restore
# restic recreates the full original path, so config/ lands several levels down
# under the staging directory it was backed up from - find it rather than guess.
SRC=$(find /tmp/restore -type d -name config -print -quit)
rsync -a "$SRC/" core@192.168.0.100:/var/media-stack/config/
ssh core@192.168.0.100 'du -sh /var/media-stack/config && ls /var/media-stack/config'
```

Caddy's certificates were captured from inside its container as root, but restore as `core`
(uid 1000) is still correct: rootless Podman maps container root to that user, so the proxy can read
its own keys back.

### 15. Start it

```bash
ssh core@192.168.0.100
systemctl --user daemon-reload

# The VPN first. Starting gluetun pulls in torrent-pod, and its Notify=healthy
# means this command does not return until the tunnel is actually up.
systemctl --user start gluetun
systemctl --user start qbittorrent joal

# Ingress next; caddy builds its image on first start, so allow several minutes.
systemctl --user start pocket-id tinyauth caddy

systemctl --user start sonarr radarr prowlarr flaresolverr jellyfin jellyseerr \
                       tdarr-server tdarr-node-01 unpackerr duckdns
```

**Starting `torrent-pod.service` alone is not enough** — a pod is a namespace, not its contents. It
would come up with no VPN and no downloaders, and nothing would obviously look wrong.

On later boots none of this is needed: every unit is `WantedBy=default.target` and Ignition enabled
lingering, so the stack starts without anyone logging in. Confirm that once:

```bash
loginctl show-user core | grep Linger        # Linger=yes
systemctl --user list-units 'net-*' --no-legend  # seven networks, all active
```

---

## Verify

Most of this battery is now `bin/verify-host.sh`, which is also what runs hourly and writes the
MOTD. Run it first; it covers the address, the mount and its SELinux label, CDI and the driver
match, firewalld, lingering, the `io` delegation, and every unit and container.

```bash
/var/media-stack/bin/verify-host.sh --routes     # --routes adds the public route walk
```

What it deliberately does **not** cover, and you should still do by hand:

```bash
# segmentation, both directions - the forbidden ones are the point
podman exec flaresolverr getent hosts sonarr  || echo "flaresolverr -> sonarr: blocked"
podman exec jellyfin     getent hosts radarr  || echo "jellyfin -> radarr: blocked"
podman exec prowlarr     getent hosts flaresolverr && echo "prowlarr -> solver: ok"
podman exec sonarr       getent hosts gluetun     && echo "sonarr -> torrent: ok"

# the VPN still is a VPN
podman exec gluetun wget -qO- https://ipinfo.io/json    # NOT the home IP

# the applications agree
#   Sonarr/Radarr/Prowlarr: download client test passes, host is "torrent"
#   Prowlarr: FlareSolverr and both app syncs pass
#   Tdarr node registered with the server
```

Then, in a browser: a passkey login, and Jellyfin playing something that transcodes.

<details>
<summary>The original hand-run battery, for reference</summary>

```bash
ip -4 -o addr show | grep 192.168.0.100
nmcli -f GENERAL.STATE,IP4.ADDRESS connection show lan
findmnt /mnt/media -o SOURCE,FSTYPE,OPTIONS      # xfs, context=...container_file_t
nvidia-ctk cdi list | head
podman exec tdarr-node-01 nvidia-smi -L          # one GPU, ordinal 0 inside the container
# routes: admin 302, watch 302, request 307, auth/id 200
for h in watch request id auth sonarr radarr prowlarr tdarr torrent fakerr; do
  printf '%-9s %s\n' $h "$(curl -s -o /dev/null -w '%{http_code}' https://$h.avanserv.com/)"
done
```

</details>

---

## Updating

**Two independent tracks, and only one of them ever needs you.**

Containers update themselves nightly via `podman-auto-update.timer`: it pulls each tracked tag,
restarts the unit, and — because every service with a healthcheck carries `Notify=healthy` —
restores the previous image if the unit fails to reach healthy. Caddy is rebuilt weekly by
`media-stack-caddy-build.timer` instead, since it is built here rather than pulled. Nothing to do.

The OS stages a deployment nightly and **never applies it**. That is the whole policy: this machine
has no console and no BMC, so a deployment that does not boot, or that boots without sshd, is a car
journey. Until greenboot is in place there is no automatic rollback either.

**The reboot procedure. Do it on a day you could physically reach the machine.**

```bash
ssh home.local
/var/media-stack/bin/verify-host.sh            # what is staged, and is everything healthy now
df -h /boot                                    # >160M free
nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader   # 0% - nothing mid-encode

# PIN THE BOOTED ONE, WHICH IS NOT INDEX 0 WHEN SOMETHING IS STAGED.
# `ostree admin pin 0` fails outright with "Cannot pin staged deployment".
idx=$(rpm-ostree status --json | jq '[.deployments[]] | map(.booted) | index(true)')
sudo ostree admin pin "$idx"
sudo systemctl reboot

until ssh -o ConnectTimeout=5 home.local true 2>/dev/null; do sleep 5; done
/var/media-stack/bin/verify-host.sh            # must pass before you walk away

# UNPIN. This is not tidying - see below.
idx=$(rpm-ostree status --json | jq '[.deployments[]] | map(.pinned) | index(true)')
sudo ostree admin pin "$idx" --unpin && sudo rpm-ostree cleanup -r
```

**"Pinning the booted deployment is free" is only true until you reboot.** `/boot` costs one slot
per *distinct kernel+initramfs*, not per deployment, and holds exactly two. At the moment you pin
it, the booted deployment already occupies the slot it runs from, so the pin costs nothing — but if
the deployment you then boot into carries a different initramfs, the pin is suddenly holding a
second full slot.

**And a firmware bump is enough to change the initramfs.** Measured on 2026-08-14: the signed rebase
changed no kernel package at all, only `linux-firmware` 20260622 → 20260810, and that alone produced
a new 146 MB slot. `/boot` went from 171 MB free to **26 MB** — a FAIL — until the old deployment was
unpinned and `rpm-ostree cleanup -r` run, which put it straight back to 171 MB.

So unpinning after verifying is not housekeeping, it is what keeps the *next* update able to write
its kernel at all. `bin/verify-host.sh` warns whenever anything is pinned for exactly this reason.
`/boot` cannot be grown: `nvme0n1p4` is XFS, which cannot be shrunk by any tool.

**An OS update changes the NVIDIA driver**, which ships inside the uCore image. The CDI spec names
that version in dozens of paths, so `verify-host.sh` asserts the spec matches the running driver —
that check is the reason it exists. uCore's `nvidia-cdi-refresh.path` regenerates it automatically;
there is deliberately no second spec in `/etc/cdi`.

**If nothing has staged for a fortnight, something is wrong** and it looks identical to a quiet
upstream. `verify-host.sh` asserts the last run's exit status and age for exactly that reason — a
ublue signing-key rotation, or a full `/boot`, would otherwise stop every update in silence.

---

## Rollback

There are two kinds, and they are wildly different in cost. Try the first.

### A bad deployment — seconds, and the everyday case

rpm-ostree keeps the previous deployment. Nothing here touches the disk image or `config/`.

```bash
rpm-ostree status                  # index 0 is booted, index 1 is where you are going
sudo rpm-ostree rollback --reboot  # swaps the default and reboots

# afterwards, the one you left is index 1 again - so this undoes the undo
sudo rpm-ostree rollback --reboot
```

Keep a known-good deployment past the two rpm-ostree retains with `sudo ostree admin pin 0` — see
the `/boot` caveat under **Updating**, and unpin once you are satisfied.

If a stage ever fails for space:

```bash
sudo rpm-ostree cleanup -bpr       # base, pending and rollback
sudo rpm-ostree upgrade
```

**A container rollback is separate and does not need a reboot at all.** The previous image is still
in local storage — the nightly `podman image prune -f` removes only *dangling* images, and a
superseded image keeps its repository digest:

```bash
podman images                                          # find the previous image ID
podman tag <old-id> lscr.io/linuxserver/sonarr:latest
systemctl --user restart sonarr
```

### Putting the pre-migration system back — the disk image

Writing to `nvme0n1` has to be done from something that is not running off it — the live
environment. **Get there first**, which is the same `kexec` as before if the installed system still
boots:

```bash
./bin/remote-kexec.sh                                            # if uCore still boots
```

**The image is on `/mnt/media`, which is on `sda` — a disk this migration never touches.** So the
restore is a local read and a local write, needing no network at all:

```bash
ssh home-live 'sudo vgchange -ay && sudo mkdir -p /var/tmp/media &&
               sudo mount -o ro /dev/mapper/vg_xfs_media-xfs_db /var/tmp/media &&
               sudo systemd-run --unit=restore --collect /bin/sh -c \
                 "zstd -dc /var/tmp/media/nvme0n1.img.zst | dd of=/dev/nvme0n1 bs=4M"'
ssh home-live 'journalctl -u restore -f'                         # 250059350016 bytes, then exit 0
ssh home-live 'sudo systemctl reboot'
```

At disk speed rather than network speed, and `systemd-run` means a dropped SSH session no longer
costs the run — the same reason the imaging was done that way.

**Leave that copy where it is.** Pulling one to the workstation and deleting the original trades a
fast local restore for a 73 GB push back over the network, to a machine with no console. There is
6.9 TB free on that disk; space was never the constraint.

A workstation copy is still worth keeping as a *second* one, since it is the only answer if `sda`
itself fails or the install went to the wrong device:

```bash
zstd -dc "$MEDIA_STACK_DISK_IMAGE" | ssh home-live 'sudo dd of=/dev/nvme0n1 bs=4M'
```

That one *is* a long pipe from the laptop and cannot be moved server-side. Do not let the machine
sleep partway through. If it breaks, redo it from the start: `dd` from byte zero is idempotent.

**If the installed system does not boot at all, this needs the console path** — the live ISO on a
USB stick, then the same `dd`. That is the case remote installation cannot rescue, and it is why the
image is taken before anything else.

You are not dependent on the image regardless. `config/` is backed up and verified, and the whole
stack is in git, so the fallback of last resort is a fresh Fedora install and `docker compose up -d`.
The image exists so a bad evening does not have to become a long one.
