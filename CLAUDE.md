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
reachable over passwordless SSH as `home`. Containers run as `PUID`/`PGID` 1000.

```bash
ssh home 'cd /var/media-stack && git status --short'   # ALWAYS do this before editing
```

**The remote has drifted from git before**, and it is easy to cause. Reconcile any drift into git
*before* making changes, or your edits will be silently clobbered or will clobber someone else's.

**Change files here, commit, then `git pull` on the server — never edit them over SSH.** Editing
the checkout directly recreates the drift, and the next `git pull` refuses to apply with "local
changes would be overwritten". The only things that legitimately change on the server are `.env`
and the runtime state under `config/`.

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

docker compose build caddy                   # after editing ingress/Dockerfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile   # routing change, no downtime
```

`docker compose config` is the closest thing to a linter here — it catches missing `.env`
variables and YAML errors without touching running containers. Run it before every `up`.

The Caddyfile can be checked without deploying it, which is worth doing since a bad one takes the
whole ingress down. `acme_dns gandi` does not exist in the stock image, so validation needs the
custom build:

```bash
docker run --rm -v "$PWD/ingress/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e DOMAIN=example.com -e PORT_TDARR_WEB=8265 -e PORT_FLOOD_WEB=3000 \
  -e PORT_QBITTORRENT_WEB=8200 -e PORT_JOAL_WEB=8221 -e GANDI_BEARER_TOKEN=dummy \
  media-stack/caddy:latest caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Architecture

**Everything is parameterised through `.env`.** Ports, paths, subnets, credentials and image
settings are all variables. Required ones use `${VAR:?err}` so compose fails loudly rather than
silently substituting empty strings. Follow that convention: `:?err` for required, bare `${VAR}`
for optional.

**Two networks, and the split is the security model:**

- `media-network` — a bridge with a pinned subnet (`NET_DOCKER_SUBNET`) that most services share
  and address each other on by container name (`http://sonarr:8989`).
- **`gluetun` is the egress chokepoint.** **qBittorrent — and only qBittorrent** — uses
  `network_mode: "service:gluetun"`, meaning it has no network stack of its own and lives inside
  the VPN container's namespace. If the VPN drops, it loses connectivity entirely. That is a
  kill-switch by construction, and it is why qBittorrent's web UI port is published on the
  *gluetun* service, not on qBittorrent. **Never give a downloader its own `networks:` entry** —
  it would leak traffic outside the VPN.

**JOAL shares that namespace too**, because it announces to trackers and would otherwise do so
from the host's own IP while qBittorrent used the VPN. Both web UIs are therefore published on
the `gluetun` service. Flood stays on the bridge — it only talks to qBittorrent's API.

**No peer port is published on the host.** With `VPN_PORT_FORWARDING=on`, incoming peers arrive
through the tunnel on the port ProtonVPN forwards, landing straight in gluetun's namespace.
That port changes on every reconnect, so `VPN_PORT_FORWARDING_UP_COMMAND` pushes it into
qBittorrent over its API each time the tunnel comes up; without that the two silently drift apart
and the client goes unconnectable. Publishing 6881 on the host would only forward to a port
nothing listens on.

`unpackerr` needs the bridge despite touching only the filesystem — it discovers what to extract
by polling the Sonarr and Radarr queue APIs.

**One media mount, not several.** Every media-touching service mounts `${DOCKER_VOLUME_MEDIA}`
(`/mnt/media`) as a single `/data`, so `downloads/` and `library/` are on one filesystem and the
\*arr apps can hardlink/atomic-move instead of copying. Mounting subdirectories separately would
break that and silently double disk usage.

## Ingress and access control

**`caddy` is the single TLS terminator**, built from `ingress/Dockerfile` because the official
image ships no DNS provider modules. All routing is `ingress/Caddyfile` — one site block per
hostname, mounted as a directory so a `git pull` replacing the file does not leave the container
holding a stale inode.

**Certificates are issued per site block, on demand, over DNS-01 against Gandi** using a Personal
Access Token (`GANDI_BEARER_TOKEN`). Consequences worth knowing:

- There is **no certificate list to maintain**. Adding a service is a CNAME plus a Caddyfile block.
- **A hostname with no block gets no certificate and fails the TLS handshake**, so unlisted names
  are closed by construction rather than by remembering to remove them.
- `*.avanserv.com` belongs to a different server and is not available here, so names stay flat and
  explicit and each new service needs its own CNAME.
- The credential is a **PAT, not the legacy `dns_gandi_api_key`** certbot used. That type is
  deprecated and `caddy-dns/gandi` will not authenticate with it.

**Access control is passkey single sign-on.** Pocket ID is the OIDC provider; Tinyauth bridges
Caddy's `forward_auth` to it, because Pocket ID has no forward-auth endpoint of its own:

```
browser ─▶ caddy ─forward_auth─▶ tinyauth ─OIDC─▶ pocket-id (passkey)
```

Two things about this that are easy to get wrong, both learned the hard way:

- **Tinyauth returns 401 with the login URL in `X-Tinyauth-Location`, not in `Location`.** Caddy
  turns that into a redirect via `handle_response`. Without it the integration still *refuses*
  requests correctly, so it looks like it works, while showing a bare 401 in the browser. The
  snippet in Tinyauth's own Caddy documentation stops short of this.
- **`POCKETID_APP_URL` must match the browser's origin exactly, port included.** WebAuthn strips
  the port when deriving the relying-party ID, but the server validates the full origin string
  separately. A mismatch fails registration at `/api/webauthn/register/finish` with an unhelpful
  "couldn't process the response from your passkey".

`watch` and `request` are the only routes not behind sign-on: both authenticate their own users,
and their clients have no browser in which to complete a passkey prompt.

**Almost nothing publishes a host port.** Caddy reaches each service by name over the bridge, so
admin ports were a second path in that sign-on did not cover. Three publishes remain, each for
something that must be spoken to without the proxy: Caddy's 80/443, Jellyfin for LAN clients, and
Gluetun's LAN proxies. **Do not add a `ports:` entry for a service Caddy can reach by name.**

## The `config/` gitignore inversion

`config/` is ignored wholesale and specific paths are re-included by exception — currently only
`config/sonarr/scripts/`. Each level has to be un-ignored in turn, because git will not descend
into an ignored directory to find an exception inside it.

Everything else under `config/` is **runtime state on the server** — application databases,
Jellyfin metadata, Caddy's certificates and ACME account, Pocket ID's passkey records. It is not
in git and (see below) is not backed up either. Treat it as precious and never assume it can be
regenerated.

If you add a config file that should be tracked, you must add a matching `!` rule.

## Known state

Conclusions from auditing the running host. Do not rediscover these:

- **`firewalld` does not protect published container ports.** Docker inserts its own DNAT and
  FORWARD rules ahead of firewalld's zone filtering, so a published port stays reachable even
  when the active zone does not allow it — verified on this host, not assumed. **Do not assume a
  firewall rule will contain a container.** Either publish to a specific interface (what
  `BIND_ADMIN`/`BIND_LAN` are for) or filter in the `DOCKER-USER` chain, the only iptables chain
  Docker leaves under your control.
- **The host OS predates the current stack design** and is being replaced rather than upgraded;
  see Target architecture below. Do not invest in host-level configuration that the migration
  will discard.
- **Images are unpinned.** Everything is `:latest` (Prowlarr is `:develop`), so there is no
  reproducibility and no way to roll back a bad image. Pinning is part of the quadlets migration.
- **`/mnt/media` is a single disk with no redundancy**, holding only re-downloadable media. It is
  treated as disposable and is deliberately not backed up. `config/` is the part that matters.
- **Transcode scratch must stay off the media disk.** `DOCKER_VOLUME_CACHE` points at the SSD
  because both Tdarr nodes otherwise read source media and write scratch to the same spindle and
  contend for seeks. Do not "simplify" it back under `DOCKER_VOLUME_MEDIA`.
- **`nv-patch.sh` is obsolete.** It lifted the NVENC concurrent-session limit, which NVIDIA raised
  to 8 for consumer GPUs in Jan 2024. Two Tdarr nodes cannot reach that ceiling. Do not port it
  forward — on an immutable host, patching a driver library in `/usr` fights OSTree every update.
- **The bridge is flat, and that is the remaining hole.** Every container can reach every other
  directly by name, bypassing Caddy and therefore sign-on entirely — confirmed by running a
  throwaway container on `media-network` and getting a response from `sonarr:8989`. The
  applications' own logins are what stand in the way, which is why **they must stay enabled**
  until the network is segmented. The sharp edge is **FlareSolverr**: its whole purpose is running
  headless Chrome against attacker-controlled indexer pages, and it currently shares a network
  with everything. Segmentation is scoped as part of the quadlets migration.
- **Gluetun's HTTP and Shadowsocks proxies are unauthenticated** (`HTTPPROXY_USER`,
  `HTTPPROXY_PASSWORD` and `SHADOWSOCKS_PASSWORD` are all empty) and bound to `BIND_LAN`. They are
  not reachable from the internet — the router does not forward 8888/8388, verified — but any LAN
  device can use them as an open proxy into the VPN. Set credentials or turn them off if unused.
- **Flood must talk to qBittorrent over the bridge**, not through the public hostname. It was
  configured with `https://torrent.avanserv.com`, which sent its polling out to the internet and
  back — and broke outright when that route went behind sign-on. Its client URL lives in
  `config/flood/db/users.db`, not in an env var.

## Target architecture

The stack is migrating off Docker Compose on a mutable host. Direction, in order:

1. **Host → [uCore](https://github.com/ublue-os/ucore) (`ucore:stable-nvidia`)**, a Fedora CoreOS
   derivative that pre-bakes the NVIDIA open driver, CUDA and `nvidia-container-toolkit`.
   Immutable, auto-updating, provisioned declaratively via Butane/Ignition.
2. **Runtime → rootless Podman quadlets.** Each service becomes a `.container` systemd unit.
   `network_mode: service:gluetun` becomes a Podman pod; `runtime: nvidia` becomes a CDI device ref.
   Note that **SELinux is enforcing on CoreOS**, so every bind mount needs `:z`/`:Z` — the current
   compose file has none.
3. **Network segmentation.** One network per trust boundary instead of today's flat bridge, so
   Caddy becomes the only path to an application. FlareSolverr gets a network shared with Prowlarr
   and nothing else; Jellyfin and the Tdarr nodes, which initiate no internal connections at all,
   stop being able to reach the \*arr apps. Caddy joins each segment individually — a shared
   "proxy" network containing everything with a UI would just re-flatten it.
4. **Secrets → sops+age** in-repo, replacing the untracked, unbacked-up `.env`.

**Ingress is already done** — Caddy, Pocket ID and Tinyauth replaced SWAG and Authelia on the
Compose stack ahead of the host migration, deliberately, so that the reinstall changes only the OS
and the runtime rather than testing every new component at once during the least recoverable step.
Their configuration carries over to quadlets unchanged.

Only after step 3 is it reasonable to drop the applications' own logins in favour of
`AuthenticationMethod=External`. Note their *"Disabled for Local Addresses"* option is never the
right tool here: Caddy and FlareSolverr are both RFC1918 addresses on the same bridge, so it
disables authentication for precisely the attacker path.

Until step 1 lands, work on the Compose stack as it exists — but avoid adding anything that will
be expensive to unwind, especially new `docker.sock` mounts or host-level package dependencies.
