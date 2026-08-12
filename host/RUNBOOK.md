# Stage 2 — migrating the host to uCore

Follow this at the machine. It assumes nothing has been done in advance except reading it once.

**The install is irreversible.** `coreos-installer` rewrites `nvme0n1`'s partition table, and there
is no undo beyond the disk image taken in step 2. Everything below is ordered so that each step's
prerequisites are already true; the failure mode of improvising the order is discovering at step 12
that something you needed was on the disk you wiped at step 6.

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

```bash
ssh home 'cd /var/media-stack && docker compose down && sync'
ssh home 'sudo dd if=/dev/nvme0n1 bs=4M' | zstd -T0 > ~/backups/nvme0n1.img.zst
```

Taken with the stack stopped and after `sync`, so the btrfs filesystem inside is **crash-consistent**
— restoring it is equivalent to recovering from a power cut, which btrfs handles. It is not a clean
snapshot, and it does not need to be.

Expect 20–40 minutes and roughly 20–35 GB. `dd` reads all 232 GB including free space; zstd
collapses the empty part.

### 3. Confirm you can still get in afterwards

Both of these are **already saved** — this is a check, not a task, and it is the check that matters
most. Without the age key there is no `.env`, and without `.env` nothing starts.

- age private key (server's copy of `~/.config/sops/age/keys.txt`)
- restic repository password

The workstation's own age key can decrypt the secrets too, so you are not locked out if the server's
copy is lost — but restoring it is the documented path.

### 4. Build the media

- Fedora CoreOS **live ISO** on a USB stick.
- Transpile the Ignition config and put it somewhere the live environment can read — a second USB
  stick, or serve it over HTTP from the workstation:

```bash
cd ~/repos/brinkflew/media-stack/host/butane
podman run --rm -i quay.io/coreos/butane:release --pretty --strict < ucore.bu > ucore.ign
```

---

## Install

### 5. Boot the live ISO

### 6. Verify the disks before touching anything

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID
```

Expect `nvme0n1` at 232.9 G with three partitions, and `sda` at 7.3 T carrying an
`LVM2_member` partition. **If `sda` is anything other than the LVM member, stop.** Confirm the media
volume's UUID is still `fce53d5f-0849-40dd-81aa-ba21819c7eeb`, because `mnt-media.mount` refers to
it by UUID and a mismatch means the stack starts with an empty library.

### 7. Install

```bash
sudo coreos-installer install /dev/nvme0n1 --ignition-file ucore.ign
```

`/dev/nvme0n1`. **Not `sda`.**

### 8. Reboot, then rebase to uCore

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/ucore:stable-nvidia
sudo systemctl reboot
```

**`nvidia-cdi.service` fails on this first boot and that is expected** — plain FCOS has no
`nvidia-ctk`. It succeeds after the rebase. Do not chase it.

### 9. Reconnect

The host key has changed, so clear the old one:

```bash
ssh-keygen -R home && ssh-keygen -R home.avanserv.com && ssh home 'rpm-ostree status'
```

---

## Restore

Strict order. Each step depends on the one before it.

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
rsync -a "$SRC/" home:/var/media-stack/config/
ssh home 'du -sh /var/media-stack/config && ls /var/media-stack/config'
```

Caddy's certificates were captured from inside its container as root, but restore as `avanserv`
(uid 1000) is still correct: rootless Podman maps container root to that user, so the proxy can read
its own keys back.

### 15. Start it

```bash
ssh home
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

If uCore does not work out, put the old system back from the live ISO:

```bash
zstd -dc ~/backups/nvme0n1.img.zst | ssh home 'sudo dd of=/dev/nvme0n1 bs=4M'
```

You are not dependent on this. `config/` is backed up and verified, and the whole stack is in git,
so the fallback of last resort is a fresh Fedora install and `docker compose up -d`. The image
exists so that a bad evening does not have to become a long one.
