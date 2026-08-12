# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-hosted server stack, currently media-focused, defined as a single Docker Compose file.
The scope is deliberately widening beyond media — prefer changes that generalise over ones that
assume the stack is only Sonarr/Radarr/Jellyfin.

| Path | What it is |
|---|---|
| `stacks/` | **what is actually running.** Rootless Podman quadlets. Change these to change the server. |
| `host/butane/` | the Ignition config that defines the host itself — applied |
| `docker-compose.yaml` | the previous runtime, kept for reference until the quadlets have run a while |
| `ingress/` | `Caddyfile` and the Caddy build with the Gandi DNS module |
| `secrets/` | every credential, sops+age encrypted; `.env` is rendered from it |

**The migration happened on 2026-08-12.** The server runs uCore with rootless Podman quadlets;
`docker-compose.yaml` is no longer deployed anywhere and editing it changes nothing. It is retained
only because it documents a configuration that demonstrably worked, and the quadlets are days old.

**The service user is `core`, uid 1000** — not `avanserv`, which no longer exists. Fedora CoreOS
ships `core` at uid 1000 and Ignition cannot create a second user there, so the account that already
held the uid was adopted. The filesystem stores uids, so `/mnt/media` and `config/` needed no chown.

There is no application code here: no build, no lint, no test suite. The unit of work is a
service definition, and the verification loop is "does the container come up and stay healthy".

## Deployment model

This repo is the source of truth. The server runs a **git checkout of it** at `/var/media-stack`,
reachable over passwordless SSH as `home` (WAN, via the router's `9122 → 22` forward) or
`home.local` (direct, `192.168.0.100`). **Prefer `home.local`** — the WAN route depends on NAT
hairpinning and on the forward still pointing at the right address.

`~/.config/containers/systemd/{common,torrent,media,infra}` are symlinks into `stacks/`, so
`git pull && systemctl --user daemon-reload` is the entire deploy — there is no copy step.

**Containers run `PUID=0`/`PGID=0`, which is not a privilege escalation.** Rootless Podman maps
container UID 0 to the invoking user, `core` (uid 1000), which is what owns `/mnt/media` and
`config/`. A container "running as root" is uid 1000 on the host. Anything *other* than 0 maps into
the subuid range (`core:100000:65536`) and cannot read the data.

```bash
ssh home.local 'cd /var/media-stack && git status --short'   # ALWAYS do this before editing
```

**The remote has drifted from git before**, and it is easy to cause. Reconcile any drift into git
*before* making changes, or your edits will be silently clobbered or will clobber someone else's.

**Change files here, commit, then `git pull` on the server — never edit them over SSH.** Editing
the checkout directly recreates the drift, and the next `git pull` refuses to apply with "local
changes would be overwritten". The only thing that legitimately differs on the server is the
runtime state under `config/`.

## Secrets

**`.env` is generated, not edited.** It is rendered from `secrets/env.sops.env` — every value
encrypted with sops+age, committed to this public repo, which is what finally puts the credentials
under version control and into a backup. Editing `.env` in place works right up until the next
render silently discards it.

```bash
sops secrets/env.sops.env      # decrypts into $EDITOR, re-encrypts on save
git commit && git push          # then on the server:
ssh home.local 'cd /var/media-stack && git pull && ./bin/render-env.sh &&
                systemctl --user daemon-reload && systemctl --user restart <affected units>'
```

- **Two age recipients**, workstation and server, so losing either machine does not lock you out.
  Their private keys are at `~/.config/sops/age/keys.txt` and belong in a password manager — they
  are the one thing here that cannot be regenerated. Adding a third recipient means editing
  `.sops.yaml` *and* running `sops updatekeys secrets/env.sops.env`; existing files are not
  re-encrypted for you.
- **The creation rule is matched against the file sops reads, not the one it writes.** Seeding
  `secrets/env.sops.env` from `.env` therefore matches as `.env`, which is why `.sops.yaml` covers
  both names. Without that it fails with an unhelpful "no matching creation rules found".
- **Variable names stay legible and empty values stay unencrypted.** That is deliberate: a diff
  should still show which credential changed. It does mean the file publishes the shape of the
  stack, which `docker-compose.yaml` already does.
- **sops' dotenv format does not preserve every comment**, so a rendered `.env` is barer than a
  hand-written one. `.env.sample` is the documentation; **update it whenever you add a variable**,
  or the next person gets `variable is not set` from `${VAR:?err}`.
- `sops` and `age` are static binaries in `~/.local/bin` on both machines, not system packages —
  `/usr/local` needs a sudo password on the server and this does not. That directory is absent from
  a non-interactive ssh `PATH`, which is why `render-env.sh` sets it itself.

## Backups

`config/` is the only part of this system that cannot be rebuilt from git, and it lives on
`nvme0n1p3` — the disk the uCore install wipes. `bin/backup-config.sh` is what makes that install
recoverable.

```bash
./bin/backup-config.sh              # from the WORKSTATION, not the server
```

It pulls rather than pushes, so the server holds no credentials for the backup destination and no
route to it — compromising the server does not get you the backups. The restic repository is at
`~/backups/media-stack` on the workstation, password at `~/.config/restic/media-stack.pw`.

**Three things it does that a plain `rsync` does not**, each of which otherwise produces a backup
that looks complete and is not:

- **Caddy's certificates are asserted present, never assumed.** Under Docker its `/data` was
  root-owned inside the container and rsync silently skipped it, so the script pulled it with
  `docker exec caddy tar`. Rootless Podman maps container root to `core`, so it copies normally now
  and that workaround is gone — but the script still **fails** if it captures no certificates. It is
  192 KB holding every TLS private key and the ACME account key, and it is exactly the kind of thing
  a permission change removes without anyone noticing.
- **Live SQLite databases are snapshotted through SQLite's backup API**, not copied. The apps run
  with WAL, so a file copy can be missing commits that live in the `-wal`.
  `bin/snapshot-databases.sh` finds them by magic bytes rather than extension — Tdarr and Jellyfin
  both use `.db` for things that are not SQLite.
- **`-wal`/`-shm` are excluded.** Restoring a stale `-wal` next to a newer `.db` is worse than
  having neither.

- **Lock files are excluded.** The backup runs with the stack live, so it captures live locks.
  qBittorrent's Qt lockfile records a pid, hostname and machine id; restored where the hostname
  differs, Qt assumes the lock is held and qBittorrent exits one second after starting, logging
  only `termination initiated`.

**Off-site**, to Scaleway Object Storage (`s3.fr-par.scw.cloud/home-server-backup`, live since
2026-08-12, 1.43 GiB stored):

```bash
./bin/backup-config.sh && ./bin/backup-offsite.sh --check    # the full routine
```

**The bucket has versioning OFF, deliberately.** `forget --prune` deletes and rewrites pack files;
with versioning on, every deletion is retained as a noncurrent version, so pruning frees nothing
while restic reports the repository shrinking — a silent, billable divergence. Object lock is off
for the same reason: it makes prune fail outright. That leaves a known gap — someone who
compromises the workstation has the API key and can delete the off-site copy — which is worth
revisiting with a separate locked bucket and a copy-only key rather than by turning these on.

It **copies the repository** rather than backing up again, so the server is untouched and both
copies hold identical, verifiable snapshots. Three deliberate choices:

- **The destination has its own password**, because `restic copy` re-encrypts blob by blob. One
  compromised credential loses one copy. The cost is that the two repositories do not deduplicate
  against each other, which is nothing at 1.4 GiB.
- **The Scaleway credentials are not in sops and must never be.** The server has no route to the
  backups and no credentials for them — the same reason `backup-config.sh` pulls rather than pushes.
  Putting them in `secrets/` would hand them to the machine they exist to protect against.
- **Retention is applied at the destination too.** `copy` does not replicate deletions, so without
  its own `forget --prune` the off-site repository grows for ever.

**What this protects against that the local repository does not:** losing the workstation. The
local repository, both age private keys and both restic passwords all live on it. Which means the
one thing that must be true is that **the age keys and both restic passwords are in the password
manager** — off-site backups you cannot decrypt are not backups.

## Commands

All of these run on the server as `core`, from `/var/media-stack`. **No `sudo`** — the stack is
rootless, and `systemctl --user` is a different unit space from `systemctl`.

```bash
git pull && systemctl --user daemon-reload    # the whole deploy; quadlets are symlinked in
./bin/render-env.sh                           # regenerate .env after a secrets change
systemctl --user restart <service>
systemctl --user status <service>
journalctl --user -u <service> -f
podman ps                                     # STATUS shows healthy/unhealthy
systemctl --user list-units --failed          # the fastest health check

systemctl --user start caddy-build            # after editing ingress/Dockerfile (~75s)
podman exec caddy caddy reload --config /etc/caddy/Caddyfile   # routing change, no downtime
```

**A unit stuck in `activating` is usually a `Restart=always` loop, not slow progress.** Read the
journal rather than waiting — the real error scrolls past between restarts, and the restart counter
tells you how long it has been failing.

There is no `docker compose config` equivalent. The nearest linter is generating the units without
starting anything, which catches syntax errors but **not** unset variables:

```bash
/usr/lib/systemd/user-generators/podman-system-generator --dryrun
```

Changing a network's subnet or options is not a live edit: a network cannot be modified in place or
removed while containers are attached, so it takes stopping the stack, `podman network rm`, and
starting again.

The Caddyfile can be checked without deploying it, which is worth doing since a bad one takes the
whole ingress down. `acme_dns gandi` does not exist in the stock image, so validation needs the
custom build:

```bash
docker run --rm -v "$PWD/ingress/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e DOMAIN=example.com -e PORT_TDARR_WEB=8265 \
  -e PORT_QBITTORRENT_WEB=8200 -e PORT_JOAL_WEB=8221 -e GANDI_BEARER_TOKEN=dummy \
  media-stack/caddy:latest caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Architecture

**Everything is parameterised through `.env`.** Ports, paths, subnets, credentials and image
settings are all variables. Required ones use `${VAR:?err}` so compose fails loudly rather than
silently substituting empty strings. Follow that convention: `:?err` for required, bare `${VAR}`
for optional.

**One network per trust boundary, and the split is the security model.** Services address each
other by container name (`http://sonarr:8989`), but only where they share a network:

| Network | Members |
|---|---|
| `net-ingress` | caddy, tinyauth, pocket-id |
| `net-arr` | caddy, sonarr, radarr, prowlarr, jellyseerr, unpackerr |
| `net-solver` | prowlarr, flaresolverr |
| `net-download` | caddy, gluetun, sonarr, radarr, prowlarr |
| `net-media` | caddy, jellyfin, jellyseerr |
| `net-transcode` | caddy, tdarr-server, tdarr-node-01, tdarr-node-02 |
| `net-egress` | duckdns |

Each has its own `NET_SUBNET_*` variable. **Caddy joins every segment individually** — a shared
"proxy" network holding everything with a UI would re-flatten the topology and buy nothing. It is
deliberately absent from `net-solver`.

**Isolation is not free under Podman, and this is the single most important difference from the
Compose stack.** Docker put every bridge in `DOCKER-ISOLATION-STAGE-2` and dropped traffic between
them, which is what made "no shared network means no route" true. **Netavark does not.** Created
plain, these seven networks were fully routable to one another — measured, not assumed: a container
on `net-solver` reached Sonarr on `net-arr` by IP, and so did `net-media`, `net-egress` and
`net-transcode`. The topology looked segmented and was flat.

Every `.network` unit therefore carries `Options=isolate=true`. **Do not remove it, and do not add a
network without it.** It constrains bridges rather than membership, so Caddy still reaches each of
the five segments it joins.

Verify a forbidden edge **by IP, from a throwaway container on the source network**, never by name
resolution: a container has one address per network it joins, a name proves only one of them, and
the unit files look identical either way.

```bash
podman run --rm --network net-solver docker.io/library/busybox nc -w3 -z <sonarr-ip> 8989
```

Distinguish *refused* from *timeout* when reading the result. Connection-refused means the packet
arrived and only the port was shut — that is not a blocked edge.

`net-solver` and `net-media` carry most of the value. FlareSolverr exists to run headless Chrome
against attacker-controlled indexer pages, so it is the likeliest thing here to be compromised;
Prowlarr is now all it can see. Jellyfin is the inverse — the most exposed service, LAN and public
— yet it initiates no internal connections at all, so it reaches nothing.

**`gluetun` is the egress chokepoint.** qBittorrent and JOAL both use
`network_mode: "service:gluetun"`, meaning neither has a network stack of its own: they live inside
the VPN container's namespace. If the VPN drops they lose connectivity entirely, which is a
kill-switch by construction. **Never give a downloader its own `networks:` entry** — it would leak
traffic outside the VPN. gluetun's own `networks:` entry is what puts all three on `net-download`.

JOAL is in there because it announces to trackers, and would otherwise do so from the host's own
IP while qBittorrent used the VPN.

**Neither has a name of its own. The address is `torrent:<port>` — the pod.** Under Compose it was
`gluetun:<port>`, because `network_mode: service:gluetun` made gluetun the container attached to
`net-download`. Under Podman the pod's **infra** container holds the network and answers to the
*pod* name, so `gluetun:8200` does not resolve at all — and neither does `qbittorrent:8200`.

Everything addressing them needs that name: the Caddyfile, and the \*arr apps' download client
settings, **which live in their databases and not in this repository** — so a `git grep` does not
find them and a restore brings the old value back. Check them through the API:

```bash
curl -H "X-Api-Key: $KEY" http://sonarr:8989/api/v3/downloadclient   # host must be "torrent"
```

This is invisible until something actually downloads, because those routes sit behind sign-on and
an unauthenticated request never reaches the backend.

**Changing a network is not a live edit**, and that covers its options as much as its subnet. Podman
will not modify a network in place, will not create one whose pool overlaps an existing one, and
will not remove one with containers attached — so a partial attempt leaves the stack half-started.
It takes stopping every unit, `podman network rm`, `systemctl --user daemon-reload`, then starting
again in order. Do it from a script running server-side: it outlives a dropped SSH session, and the
half-way state is one where nothing is reachable.

**No peer port is published on the host.** With `VPN_PORT_FORWARDING=on`, incoming peers arrive
through the tunnel on the port ProtonVPN forwards, landing straight in gluetun's namespace.
That port changes on every reconnect, so `VPN_PORT_FORWARDING_UP_COMMAND` pushes it into
qBittorrent over its API each time the tunnel comes up; without that the two silently drift apart
and the client goes unconnectable. Publishing 6881 on the host would only forward to a port
nothing listens on.

`unpackerr` needs `net-arr` despite touching only the filesystem — it discovers what to extract
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

**Almost nothing publishes a host port.** Caddy reaches each service by name over its network, so
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

- **`firewalld` now governs published ports, which is the reverse of the Docker host.** Under
  Docker a published port stayed reachable whatever the zone allowed, because Docker's DNAT ran
  ahead of firewalld's filtering. Rootless Podman publishes through a userspace `rootlessport`
  process that binds like any other daemon, so firewalld's INPUT rules apply normally — and the
  `FedoraServer` zone ships allowing only `ssh`, `cockpit` and `dhcpv6-client`. **Ports are now
  closed by default rather than open by default.** A new published port needs a matching
  `firewall-cmd` rule in `firewall-stack-ports.service`, or it is unreachable while the container
  looks perfectly healthy. The symptom is `No route to host` — firewalld rejects rather than drops
  — on a port whose container is logging that it is serving.
- **SELinux blocks `/dev/net/tun` until `container_use_devices` is on.** The udev rule and
  `AddDevice=` are both necessary and neither is sufficient. It presents as gluetun's
  `ERROR checking TUN device: TUN device is not available`, with **no AVC logged**, while opening
  the same node as `core` on the host succeeds — and it takes qBittorrent and JOAL down too. Note
  `container_use_dri_devices` is already on in uCore, so the GPUs work while the tunnel does not.
- **Podman does not create missing bind-mount source directories; Docker did.** A fresh host has
  none of the scratch or log paths that no backup restores. With `Restart=always` this is a silent
  5-second retry loop rather than a visible failure — the Tdarr units reached restart 126. Audit
  with: expand every `Volume=` in `stacks/` against `.env` and test each host path.
- **Podman will not guess a registry.** An unqualified `FROM caddy:2` fails under systemd with
  `short-name resolution enforced but cannot prompt without a TTY`. Every image reference must be
  fully qualified; all of them are, and are digest-pinned.
- **Every quadlet that interpolates a variable needs its own `EnvironmentFile=`**, `.network` units
  included. Unlike Compose's `${VAR:?err}`, systemd expands an unset variable to an empty string
  and logs it at info level, so the visible error is podman's — `Error: invalid CIDR address:` —
  three units away from the cause.
- **`/mnt` is a symlink to `/var/mnt` on CoreOS**, as `/home` is to `/var/home`. systemd refuses a
  mount unit whose path is not canonical, so the unit is `var-mnt-media.mount` with
  `Where=/var/mnt/media`. Consumers can still say `/mnt/media`. It fails on a completely healthy
  disk, with `vgs`, `lvs` and `/dev/disk/by-uuid` all looking correct.
- **Quadlet's `Environment=` splits on whitespace.** Compose took a value with spaces as one string;
  quadlet reads the line as space-separated `KEY=VALUE` pairs and **silently truncates at the first
  space**. Three settings were cut on migration — the OIDC scope list, a display name, and gluetun's
  port-forward command. Any literal containing a space must be quoted:
  `Environment="KEY=a b c"`. `${VAR}` references are safe; systemd substitutes those into
  `ExecStart` as single arguments. Audit with: every `^Environment=` line whose value contains a
  space and does not start with a quote.
- **A 302 from an admin route proves the proxy and sign-on, not the service.** An unauthenticated
  request never reaches the backend, so the whole route battery passes with a backend that is down.
  qBittorrent was crash-looping while `torrent` returned a healthy-looking 302. Check backends by
  connecting to them from their own network.
- **Restoring a config taken from a running stack can carry live lock files.** qBittorrent's Qt
  lockfile stores the pid, hostname and machine id; on a host where the hostname does not match, Qt
  assumes the lock is held and qBittorrent **exits one second after starting, logging only
  "termination initiated"** — no error, nothing naming the lock. `bin/backup-config.sh` now excludes
  them.
- **`WebUI\LocalHostAuth` must be `false` for the port-forward push to work**, and it was `true`
  — so `VPN_PORT_FORWARDING_UP_COMMAND` had been getting a 403 and the forwarded port never reached
  qBittorrent. This predates the migration; it came in with the restored config. "Localhost" here is
  inside gluetun's namespace, which only gluetun, qBittorrent and JOAL share, so this is not the
  same as exposing the API.
- **The host is uCore `stable-nvidia`, immutable and rpm-ostree managed.** `/usr` is read-only, so
  host-level tools go in `~/.local/bin` (which is where `sops` and `age` live). Host configuration
  belongs in `host/butane/ucore.bu` — anything applied only over SSH is undocumented state that the
  next reinstall loses. Ignition runs **once, at first boot**, so editing `ucore.bu` does not change
  the running machine; a change has to be applied by hand *and* committed there.
- **Zincati is disabled.** Stock FCOS delegates updates to it, and `rpm-ostree` refuses to act while
  a driver owns them — a manual rebase needs `--bypass-driver`. It also tracked the FCOS stream we
  rebased away from. uCore brings its own update mechanism.
- **Images are unpinned.** Everything is `:latest` (Prowlarr is `:develop`), so there is no
  reproducibility and no way to roll back a bad image. Pinning is part of the quadlets migration.
- **`/mnt/media` is a single disk with no redundancy**, holding only re-downloadable media. It is
  treated as disposable and is deliberately not backed up. `config/` is the part that matters.
- **Transcode scratch must stay off the media disk.** `DOCKER_VOLUME_CACHE` points at the SSD
  because both Tdarr nodes otherwise read source media and write scratch to the same spindle and
  contend for seeks. Do not "simplify" it back under `DOCKER_VOLUME_MEDIA`.
- **`nv-patch.sh` has been deleted, and should not come back.** It lifted the NVENC
  concurrent-session limit, which NVIDIA raised to 8 for consumer GPUs in Jan 2024, and two Tdarr
  nodes cannot reach that ceiling. On an immutable host, patching a driver library in `/usr` would
  fight OSTree every update.
- **`config/` is on the disk the migration wipes.** `/var/media-stack/config` is 6.3 GB on
  `nvme0n1p3`; `/mnt/media` is a separate 7.3 TB XFS volume on LVM on `sda` and survives only
  because it is a different device. The Stage 0 backup predates Caddy, Pocket ID and Tinyauth, so
  it would not restore sign-on. **Back up and verify a restore before booting any installer.**
- **The bridge is no longer flat, and the forbidden edges are verified.** FlareSolverr cannot reach
  Sonarr on either of its addresses, nor the torrent namespace, tested by IP from inside the
  container rather than by name resolution alone. Jellyfin, the Tdarr nodes and DuckDNS are
  likewise sealed off. **The applications' own logins must still stay enabled**: segmentation is
  defence in depth, and `net-arr` remains flat *within itself* — anything on it reaches every other
  member. See Target architecture for when `AuthenticationMethod=External` becomes defensible.
- **The remaining internal exposure is Prowlarr.** It is the only service on `net-solver`, so it is
  the single hop between a compromised FlareSolverr and everything else. That is the reason its own
  login matters more than the others', not less.
- **Gluetun's HTTP and Shadowsocks proxies are unauthenticated** (`HTTPPROXY_USER`,
  `HTTPPROXY_PASSWORD` and `SHADOWSOCKS_PASSWORD` are all empty) and bound to `BIND_LAN`. They are
  not reachable from the internet — the router does not forward 8888/8388, verified — but any LAN
  device can use them as an open proxy into the VPN. Set credentials or turn them off if unused.
- **Services must address each other over their shared network, never a public hostname.** Flood was
  configured with `https://torrent.avanserv.com`, so its polling left the network and came back
  through the proxy — and stopped working entirely once that route required a session. A container
  reaching another container through the front door is always a mistake; it is slower, it depends
  on DNS and NAT hairpinning, and it breaks the moment authentication is added.
- **Tinyauth still breaks that rule and has not been fixed.** Its `TOKENURL` and `USERINFOURL` are
  `https://id.${DOMAIN}/...`, so every sign-on's token exchange leaves the network and hairpins
  back through the router. It works, but it makes login depend on NAT hairpinning — the one thing
  that must not break. `AUTHURL` genuinely has to stay public, since the browser follows it; the
  other two could be `http://pocket-id:1411/...`. Untested: Pocket ID may issue an `iss` claim
  Tinyauth rejects, and the symptom would be sign-on failing at the callback.

## Target architecture

**Steps 1 and 2 are done.** The host is uCore `stable-nvidia` and every service is a rootless Podman
quadlet: `network_mode: service:gluetun` became a Podman pod, `runtime: nvidia` became CDI device
refs, and every bind mount carries `:z`/`:Z` except `/mnt/media`, which is labelled once at mount
time by `context=` instead of relabelling 7.3 TB per container start.

Doing ingress, segmentation and secrets on the Compose stack first was the right call, but not for
the reason given at the time. The claim was that their configuration would "carry over unchanged".
**It did not** — segmentation had to be rebuilt with `isolate=true` because netavark does not
inherit Docker's inter-bridge isolation, and ingress needed firewalld rules that Docker made
unnecessary. What carried over was the *design*, and the fact that it had been proven to work: when
FlareSolverr could reach Sonarr on the new host, the question was "why is this different here",
not "was this ever right".

Remaining, in order:

3. **A cloud backup target** — `restic copy` to a second repository. The repository, the age keys
   and the restic password are still all on the one workstation, which is the outstanding gap.
4. **Monitoring**, so a failed unit surfaces without someone running `systemctl --user --failed`.
5. **`podman-auto-update`** — the units are digest-pinned, which is the prerequisite; auto-update is
   the thing that makes pinning maintainable rather than a slow drift into staleness.

**The applications keep their own logins.** Segmentation narrowed who can reach them; it did not
reduce `net-arr` to a single caller, so `AuthenticationMethod=External` would still trust five
containers rather than just Caddy. Revisit it only if those segments are split further, and note
that their *"Disabled for Local Addresses"* option is never the right tool here: Caddy and every
other container are RFC1918 addresses, so it disables authentication for precisely the attacker
path.

Until step 1 lands, work on the Compose stack as it exists — but avoid adding anything that will
be expensive to unwind, especially new `docker.sock` mounts or host-level package dependencies.
