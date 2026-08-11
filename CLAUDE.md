# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-hosted server stack, currently media-focused, defined as a single Docker Compose file.
The scope is deliberately widening beyond media — prefer changes that generalise over ones that
assume the stack is only Sonarr/Radarr/Jellyfin.

There is no application code here: no build, no lint, no test suite. The unit of work is a
service definition, and the verification loop is "does the container come up and stay healthy".

## Deployment model

This repo is the source of truth. The server runs a **git checkout of it** at `/var/media-stack`,
reachable over passwordless SSH as `home` (Fedora, user `avanserv`, `PUID`/`PGID` 1000).

```bash
ssh home 'cd /var/media-stack && git status --short'   # ALWAYS do this before editing
```

**The remote has drifted from git before** — uncommitted compose edits, extra nginx confs and a
`jellyskin.css` that exist only on the server. Check for drift and reconcile it into git before
making changes, or your edits will be silently clobbered or will clobber someone else's.

`.env` lives only on the server and is intentionally untracked. `.env.sample` is the tracked
documentation of every variable; **update it whenever you add a variable**, or the next person
gets `variable is not set` errors from `${VAR:?err}`.

## Commands

All of these run on the server, from `/var/media-stack`:

```bash
docker compose config                    # validate YAML + .env interpolation — do this first
docker compose up -d                     # apply changes (only recreates what changed)
docker compose up -d --force-recreate <service>
docker compose logs -f --tail=100 <service>
docker compose ps                        # STATUS column shows healthy/unhealthy
docker compose pull && docker compose up -d   # update images
```

`docker compose config` is the closest thing to a linter here — it catches missing `.env`
variables and YAML errors without touching running containers. Run it before every `up`.

## Architecture

**Everything is parameterised through `.env`.** Ports, paths, subnets, credentials and image
settings are all variables. Required ones use `${VAR:?err}` so compose fails loudly rather than
silently substituting empty strings. Follow that convention: `:?err` for required, bare `${VAR}`
for optional.

**Two networks, and the split is the security model:**

- `media-network` — a bridge with a pinned subnet (`NET_DOCKER_SUBNET`) that most services share
  and address each other on by container name (`http://sonarr:8989`).
- **`gluetun` is the egress chokepoint.** qBittorrent, Flood and JOAL use
  `network_mode: "service:gluetun"`, meaning they have no network stack of their own — they live
  inside the VPN container's namespace. If the VPN drops, they lose connectivity entirely. That
  is a kill-switch by construction, and it is why qBittorrent's web UI port is published on the
  *gluetun* service, not on qBittorrent. **Never give a downloader its own `networks:` entry** —
  it would leak traffic outside the VPN.

`unpackerr` runs `network_mode: none`. It only touches the filesystem.

**One media mount, not several.** Every media-touching service mounts `${DOCKER_VOLUME_MEDIA}`
(`/mnt/media`) as a single `/data`, so `downloads/` and `library/` are on one filesystem and the
\*arr apps can hardlink/atomic-move instead of copying. Mounting subdirectories separately would
break that and silently double disk usage.

**`swag` is the single TLS terminator.** It holds the Let's Encrypt certs (DNS-01 via the DuckDNS
plugin) and proxies to everything else. Per-service routing lives in
`config/swag/nginx/proxy-confs/*.subdomain.conf`, and those files *are* tracked — see below.

## The `config/` gitignore inversion

`.gitignore` uses an allowlist, which is easy to break. `config/` is ignored wholesale, then
specific paths are re-included: `config/swag/nginx/*.conf`, `config/swag/nginx/proxy-confs/*.conf`,
`config/swag/www/`, and `config/sonarr/scripts/`.

Everything else under `config/` is **runtime state on the server** — application databases,
Jellyfin metadata, TLS private keys, session stores. It is not in git and (see below) is not
backed up either. Treat it as precious and never assume it can be regenerated.

If you add a config file that should be tracked, you must add a matching `!` rule.

## Known state

Findings from an audit of the running host. Do not rediscover these:

- **The host OS is EOL.** Fedora 37 Workstation, unsupported since 2023-11-14, several hundred
  pending updates, running a full GNOME desktop. It is being replaced (see below).
- **Services are over-exposed.** `firewalld` is on the `FedoraWorkstation` zone, which opens
  TCP+UDP 1025–65535, and every container publishes on `0.0.0.0` while the host holds a public
  IPv6. Admin UIs are reachable directly, bypassing SWAG and Authelia. Publish new ports as
  `127.0.0.1:${PORT_X}:NNNN`.
- **Images are unpinned.** Everything is `:latest` (Prowlarr is `:develop`), so there is no
  reproducibility and no way to roll back a bad image.
- **`config/` has no backup**, and `/mnt/media` is a single 7.3T disk with no redundancy.
- **An auth migration is half-finished** — Authelia is running, but Tinyauth nginx confs exist on
  the server. Pick a direction before adding new protected services.
- **`nv-patch.sh` is obsolete.** It lifted the NVENC concurrent-session limit, which NVIDIA raised
  to 8 for consumer GPUs in Jan 2024. The two RTX 3060 Tis cannot hit that ceiling with two Tdarr
  nodes. Do not port it forward.
- **Bug: unpackerr never extracts Radarr archives.** `UN_RADARR_0_PATHS_0=/data/torrents/radarr`,
  but there is no `/mnt/media/torrents` — the real path is `/data/downloads/radarr`, which is
  what the Sonarr entry correctly uses.

## Target architecture

The stack is migrating off Docker Compose on a mutable host. Direction, in order:

1. **Host → [uCore](https://github.com/ublue-os/ucore) (`ucore:stable-nvidia`)**, a Fedora CoreOS
   derivative that pre-bakes the NVIDIA open driver, CUDA and `nvidia-container-toolkit`.
   Immutable, auto-updating, provisioned declaratively via Butane/Ignition.
2. **Runtime → rootless Podman quadlets.** Each service becomes a `.container` systemd unit.
   `network_mode: service:gluetun` becomes a Podman pod; `runtime: nvidia` becomes a CDI device ref.
   Note that **SELinux is enforcing on CoreOS**, so every bind mount needs `:z`/`:Z` — the current
   compose file has none.
3. **Ingress → Caddy** replacing SWAG, with a static `Caddyfile` in git and `forward_auth` to
   Tinyauth. DuckDNS stays.
4. **Secrets → sops+age** in-repo, replacing the untracked, unbacked-up `.env`.

Until step 1 lands, work on the Compose stack as it exists — but avoid adding anything that will
be expensive to unwind, especially new `docker.sock` mounts or host-level package dependencies.
