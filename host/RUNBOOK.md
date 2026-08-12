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

**Run it on the server, detached, writing to the media disk** — not as a pipe from a laptop. This
takes an hour or more, and any pipe held open across it is a liability: a lid closing, a suspend, a
Wi-Fi handover, and it dies at 40 GB with nothing resumable. `systemd-run` outlives the SSH session
entirely, and the server does not go to sleep.

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

When the unit has exited, pull it down and free the space. `rsync -P` resumes, so a dropped laptop
costs seconds rather than the whole run:

```bash
rsync -P home.local:/mnt/media/nvme0n1.img.zst ~/backups/
ssh home.local 'sudo rm /mnt/media/nvme0n1.img.zst'
ssh home.local 'cd /var/media-stack && docker compose up -d'      # bring it back until the real run
```

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
ssh core@192.168.0.100 'cat /etc/os-release | head -2; ip -4 -o addr show scope global'
ssh core@192.168.0.100 'lsblk -o NAME,SIZE,FSTYPE,LABEL -d'
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
ssh core@192.168.0.100 'lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID'
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
ssh avanserv@192.168.0.100 'sudo rpm-ostree rebase \
  ostree-unverified-registry:ghcr.io/ublue-os/ucore:stable-nvidia && sudo systemctl reboot'
```

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
`ssh avanserv@192.168.0.100` — the address is now pinned statically by the Ignition config, so it is
the same one as before.

### 10. The repository

```bash
sudo mkdir -p /var/media-stack && sudo chown avanserv:avanserv /var/media-stack
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

**As `avanserv`, not with sudo.** restic recreates files owned by the user running it, and uid 1000
is precisely what rootless Podman maps container root to — which is what makes `PUID=0` in the
quadlets correct. Restoring as root produces a config tree no container can write.

From the workstation:

```bash
export RESTIC_REPOSITORY=~/backups/media-stack RESTIC_PASSWORD_FILE=~/.config/restic/media-stack.pw
restic restore latest --target /tmp/restore
# restic recreates the full original path, so config/ lands several levels down
# under the staging directory it was backed up from - find it rather than guess.
SRC=$(find /tmp/restore -type d -name config -print -quit)
rsync -a "$SRC/" avanserv@192.168.0.100:/var/media-stack/config/
ssh avanserv@192.168.0.100 'du -sh /var/media-stack/config && ls /var/media-stack/config'
```

Caddy's certificates were captured from inside its container as root, but restore as `avanserv`
(uid 1000) is still correct: rootless Podman maps container root to that user, so the proxy can read
its own keys back.

### 15. Start it

```bash
ssh avanserv@192.168.0.100
systemctl --user daemon-reload

# The VPN first. Starting gluetun pulls in torrent-pod, and its Notify=healthy
# means this command does not return until the tunnel is actually up.
systemctl --user start gluetun
systemctl --user start qbittorrent joal

# Ingress next; caddy builds its image on first start, so allow several minutes.
systemctl --user start pocket-id tinyauth caddy

systemctl --user start sonarr radarr prowlarr flaresolverr jellyfin jellyseerr \
                       tdarr-server tdarr-node-01 tdarr-node-02 unpackerr duckdns
```

**Starting `torrent-pod.service` alone is not enough** — a pod is a namespace, not its contents. It
would come up with no VPN and no downloaders, and nothing would obviously look wrong.

On later boots none of this is needed: every unit is `WantedBy=default.target` and Ignition enabled
lingering, so the stack starts without anyone logging in. Confirm that once:

```bash
loginctl show-user avanserv | grep Linger        # Linger=yes
systemctl --user list-units 'net-*' --no-legend  # seven networks, all active
```

---

## Verify

Run the same battery this stack was signed off with. Anything less and you are guessing.

```bash
# the address held, which is what the router's port forward depends on.
# check this FIRST - if it moved, fix it before you lose the session you are in.
ip -4 -o addr show | grep 192.168.0.100
nmcli -f GENERAL.STATE,IP4.ADDRESS connection show lan

# the media disk mounted with the right SELinux label - not just mounted
findmnt /mnt/media -o SOURCE,FSTYPE,OPTIONS      # xfs, context=...container_file_t
ls /mnt/media/library | head

# GPUs visible through CDI
nvidia-ctk cdi list | head
podman exec tdarr-node-01 nvidia-smi -L          # two RTX 3060 Ti across the two nodes

# segmentation, both directions - the forbidden ones are the point
podman exec flaresolverr getent hosts sonarr  || echo "flaresolverr -> sonarr: blocked"
podman exec jellyfin     getent hosts radarr  || echo "jellyfin -> radarr: blocked"
podman exec prowlarr     getent hosts flaresolverr && echo "prowlarr -> solver: ok"
podman exec sonarr       getent hosts gluetun     && echo "sonarr -> torrent: ok"

# routes: admin 302, watch 302, request 307, auth/id 200
for h in watch request id auth sonarr radarr prowlarr tdarr torrent fakerr; do
  printf '%-9s %s\n' $h "$(curl -s -o /dev/null -w '%{http_code}' https://$h.avanserv.com/)"
done

# the VPN still is a VPN
podman exec gluetun wget -qO- https://ipinfo.io/json    # NOT the home IP

# the applications agree
#   Sonarr/Radarr/Prowlarr: download client test passes
#   Prowlarr: FlareSolverr and both app syncs pass
#   both Tdarr nodes registered
```

Then, in a browser: a passkey login, and Jellyfin playing something that transcodes.

---

## Rollback

Putting the old system back means writing to `nvme0n1`, so it has to be done from something that is
not running off it — the live environment. **Get there first**, which is the same `kexec` as before
if the installed system still boots:

```bash
./bin/remote-kexec.sh                                            # if uCore still boots
zstd -dc ~/backups/nvme0n1.img.zst | ssh core@192.168.0.100 'sudo dd of=/dev/nvme0n1 bs=4M'
ssh core@192.168.0.100 'sudo systemctl reboot'
```

**If the installed system does not boot at all, this needs the console path** — the live ISO on a
USB stick, then the same `dd`. That is the case remote installation cannot rescue, and it is why the
image is taken before anything else.

You are not dependent on the image regardless. `config/` is backed up and verified, and the whole
stack is in git, so the fallback of last resort is a fresh Fedora install and `docker compose up -d`.
The image exists so a bad evening does not have to become a long one.
