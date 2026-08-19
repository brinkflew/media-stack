# Networking, ingress and access control

Lifted whole from `CLAUDE.md` on 2026-08-19. Nothing here was rewritten.

One network per trust boundary, and the split IS the security model. `Options=isolate=true` is
the load-bearing part - netavark does not inherit Docker's inter-bridge isolation.

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
| `net-arr` | caddy, sonarr, radarr, prowlarr, jellyseerr, unpackerr, bazarr |
| `net-solver` | prowlarr, flaresolverr |
| `net-download` | caddy, gluetun, sonarr, radarr, prowlarr |
| `net-media` | caddy, jellyfin, jellyseerr |
| `net-transcode` | caddy, tdarr-server, tdarr-node-01 |
| `net-egress` | duckdns |
| `net-metrics` | caddy, prometheus, node-exporter, alertmanager, ntfy-alertmanager, ntfy |
| `net-dashboard` | caddy, dashboard |
| `net-agents` | caddy, windmill-db, windmill-server, windmill-worker, windmill-worker-verify |

Each has its own `NET_SUBNET_*` variable. **Caddy joins every segment individually** - a shared
"proxy" network holding everything with a UI would re-flatten the topology and buy nothing. It is
deliberately absent from `net-solver` and from `net-egress`.

**`net-dashboard` holds two containers and exists so that it can hold two.** The obvious home for
the dashboard was `net-metrics`, since Prometheus is what it reads, and that is the wrong answer:
membership there would let it open a connection to `prometheus:9090` **directly**, behind the
`/api/v1/admin/*` refusal the Caddyfile puts at every public entrance - and Prometheus runs with
`--web.enable-admin-api`, which carries `delete_series`. So the dashboard queries Prometheus the
same way the browser does, through Caddy, past the guard. It holds no credential, makes no outbound
request, and serves a static bundle plus one read-only JSON, which is what makes a segment of its
own cheap rather than fussy.

**`net-metrics` is the one segment that could re-create that mistake, and the design inverts it to
avoid doing so.** The obvious metrics topology puts an exporter for each application on both
`net-metrics` and that application's own segment - which leaves `net-metrics` adjoining `net-arr`,
`net-download`, `net-media` and `net-transcode` at once, i.e. exactly the shared proxy network the
paragraph above rejects, wearing a different name. **Prometheus multi-homes instead; exporters never
do.** It joins those segments as a pure *client*, with its listener pinned to its `net-metrics`
address, so nothing on `net-arr` can open a connection to it - one container to harden rather than
eight, and no exporter holds a credential outside the segment that already holds it.

**Isolation is not free under Podman, and this is the single most important difference from the
Compose stack.** Docker put every bridge in `DOCKER-ISOLATION-STAGE-2` and dropped traffic between
them, which is what made "no shared network means no route" true. **Netavark does not.** Created
plain, the seven networks that existed then were fully routable to one another - measured, not
assumed: a container
on `net-solver` reached Sonarr on `net-arr` by IP, and so did `net-media`, `net-egress` and
`net-transcode`. The topology looked segmented and was flat.

Every `.network` unit therefore carries `Options=isolate=true`. **Do not remove it, and do not add a
network without it.** It constrains bridges rather than membership, so Caddy still reaches each of
the eight segments it joins.

Verify a forbidden edge **by IP, from a throwaway container on the source network**, never by name
resolution: a container has one address per network it joins, a name proves only one of them, and
the unit files look identical either way.

```bash
podman run --rm --network net-solver docker.io/library/busybox nc -w3 -z <sonarr-ip> 8989
```

Distinguish *refused* from *timeout* when reading the result. Connection-refused means the packet
arrived and only the port was shut - that is not a blocked edge.

`net-solver` and `net-media` carry most of the value. FlareSolverr exists to run headless Chrome
against attacker-controlled indexer pages, so it is the likeliest thing here to be compromised;
Prowlarr is now all it can see. Jellyfin is the inverse - the most exposed service, LAN and public
- yet it initiates no internal connections at all, so it reaches nothing.

**`gluetun` is the egress chokepoint.** qBittorrent and JOAL both use
`network_mode: "service:gluetun"`, meaning neither has a network stack of its own: they live inside
the VPN container's namespace. If the VPN drops they lose connectivity entirely, which is a
kill-switch by construction. **Never give a downloader its own `networks:` entry** - it would leak
traffic outside the VPN. gluetun's own `networks:` entry is what puts all three on `net-download`.

JOAL is in there because it announces to trackers, and would otherwise do so from the host's own
IP while qBittorrent used the VPN.

**Neither has a name of its own. The address is `torrent:<port>` - the pod.** Under Compose it was
`gluetun:<port>`, because `network_mode: service:gluetun` made gluetun the container attached to
`net-download`. Under Podman the pod's **infra** container holds the network and answers to the
*pod* name, so `gluetun:8200` does not resolve at all - and neither does `qbittorrent:8200`.

Everything addressing them needs that name: the Caddyfile, and the \*arr apps' download client
settings, **which live in their databases and not in this repository** - so a `git grep` does not
find them and a restore brings the old value back. Check them through the API:

```bash
curl -H "X-Api-Key: $KEY" http://sonarr:8989/api/v3/downloadclient   # host must be "torrent"
```

This is invisible until something actually downloads, because those routes sit behind sign-on and
an unauthenticated request never reaches the backend.

**Changing a network is not a live edit**, and that covers its options as much as its subnet. Podman
will not modify a network in place, will not create one whose pool overlaps an existing one, and
will not remove one with containers attached - so a partial attempt leaves the stack half-started.
It takes stopping every unit, `podman network rm`, `systemctl --user daemon-reload`, then starting
again in order. Do it from a script running server-side: it outlives a dropped SSH session, and the
half-way state is one where nothing is reachable.

**No peer port is published on the host.** With `VPN_PORT_FORWARDING=on`, incoming peers arrive
through the tunnel on the port ProtonVPN forwards, landing straight in gluetun's namespace.
That port changes on every reconnect, so `VPN_PORT_FORWARDING_UP_COMMAND` pushes it into
qBittorrent over its API each time the tunnel comes up; without that the two silently drift apart
and the client goes unconnectable. Publishing 6881 on the host would only forward to a port
nothing listens on.

`unpackerr` needs `net-arr` despite touching only the filesystem - it discovers what to extract
by polling the Sonarr and Radarr queue APIs.

**One media mount, not several.** Every service that has to move files mounts `${DOCKER_VOLUME_MEDIA}`
(`/mnt/media`) as a single `/data`, so `downloads/` and `library/` are on one filesystem and the
\*arr apps can hardlink/atomic-move instead of copying. Mounting subdirectories separately would
break that and silently double disk usage. Verified working: an imported film is `links=2` with its
seeding download, and the two paths share their bytes.

**Jellyfin is the deliberate exception** - it mounts only `library/` at `/data/media`, because it
never moves a file and has no business seeing `downloads/`. Do not "fix" it to match the others.

## Ingress and access control

**`caddy` is the single TLS terminator**, built from `apps/caddy/Dockerfile` because the official
image ships no DNS provider modules. All routing is `apps/caddy/Caddyfile` - one site block per
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
browser --> caddy --forward_auth--> tinyauth --OIDC--> pocket-id (passkey)
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

`watch`, `request` and `ntfy` are the only routes not behind sign-on: each authenticates its own
users, and their clients have no browser in which to complete a passkey prompt. **`agents` is
deliberately not a fourth**, and the reason is the inverse of theirs: the resume URLs that approve an
agent's work travel by ntfy, which is *already* outside sign-on, so an unauthenticated approval path
would make the ntfy credential sufficient to merge. The cost is that a Pocket ID outage blocks
approvals - which is the correct direction, since an autonomous agent whose gatekeeper is down
should fail closed. **`ntfy` is the one
that looks wrong and is not** - an alerting endpoint outside sign-on invites the obvious objection,
but the client is a phone app in exactly the position a TV is, and `auth-default-access: deny-all`
means the hostname on its own reaches nothing. Alertmanager and the bridge get **no** public route;
the bridge's Silence button would require one, and that trade was declined. See `docs/observability.md`.

**Almost nothing publishes a host port.** Caddy reaches each service by name over its network, so
admin ports were a second path in that sign-on did not cover. **Two publishes face the LAN**, each
for something that must be spoken to without the proxy: Caddy's 80/443, and Jellyfin for LAN
clients. Gluetun's used to be a third and is gone with its proxies. **Do not add a `ports:` entry
for a service Caddy can reach by name.**

**There is a third publish and it is a different kind of thing, so the rule above needs its
carve-out spelled out rather than left to be inferred.** `windmill-server` publishes
`127.0.0.1:${PORT_WINDMILL_HTTP}:8000` - the first service here reachable only from the host.
Caddy *can* reach it by name over `net-agents`, so on the rule as written this publish looks like a
violation. It is not, and the justification is not about Caddy at all: **`conduct` runs on the host
as a `systemd --user` unit**, because no container may reach the podman socket and forking podman is
the whole of its job, so it cannot join a bridge and cannot be reached by name from one. The
alternative was a listener on the bridge gateway plus a firewalld hole, which would have given the
internet-facing container an RPC that spawns `claude`. The arrow is inverted instead: `conduct`
polls Windmill, and Windmill has no route to the host.

**A loopback publish is not the same object as a LAN one, in two ways that matter.** firewalld never
sees it - packets to `127.0.0.1` do not traverse the INPUT chain - so it needs no rule in
`firewall-stack-ports.service` and gets no protection from one either; `host/butane/ucore.bu` is
untouched by it, which is worth something on a host where Ignition has already run. And
`bin/lint-repo.sh` cannot tell the two apart: leg 6 compares only the text after the last `:`, so
`8000` is all it checks. That is why `topology.ts` writes the bind address into the mapping string -
it is the only place a reader is shown which kind this is.
