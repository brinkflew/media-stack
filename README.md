# home-server

A self-hosted server, defined declaratively. Media-focused today, deliberately widening.

Everything reaches the outside world through one reverse proxy on ports 80 and 443, behind passkey
single sign-on. There are no passwords to phish: authentication is a WebAuthn signature from a
device you already carry.

## What is in here

| Path | What it is |
|---|---|
| `stacks/` | what is actually running: rootless Podman quadlets, one directory per trust boundary |
| `apps/` | files that get deployed into containers: the Caddyfile, Tdarr's plugin, Sonarr's scripts, Jellyfin's CSS |
| `host/butane/` | the host itself, as an Ignition config |
| `host/systemd/` | units that run on the host rather than in a container |
| `host/RUNBOOK.md` | the migration procedure, and the restore and rollback paths |
| `secrets/` | every credential, encrypted with sops+age |
| `bin/` | deploy, backup and maintenance scripts |
| `docs/` | conclusions from auditing the running host, so they are not rediscovered |

One rule holds the two halves apart: **unit definitions live in `stacks/`, and the files those units
deploy live in `apps/`.**

## Shape of it

Seven container networks, one per trust boundary, so a compromised container reaches only what it
genuinely needs to talk to. The proxy is the only thing that joins more than one. The torrent client
and the tracker announcer have no network stack of their own: they live inside the VPN container's
namespace, which makes the kill-switch structural rather than a firewall rule someone has to
maintain.

Certificates are issued per hostname on demand over DNS-01, so adding a service is a DNS record and
a block in the Caddyfile, and a hostname nobody has configured simply fails the TLS handshake.

`CLAUDE.md` is the real documentation: architecture, and the reasoning behind each decision. The
things learned the hard way are indexed there and written out in `docs/known-state.md`.

## Direction

Runs on an immutable [uCore](https://github.com/ublue-os/ucore) host with rootless Podman quadlets,
migrated from Fedora 37 and Docker Compose on 2026-08-12.

---

**Everything that can update itself does, on separate tracks.** Containers follow tags and are
updated nightly by `podman-auto-update`, which restores the previous image if a unit fails to reach
healthy. The OS stages a new deployment nightly and **never reboots on its own**: the machine has no
console and no BMC, so applying it is a deliberate act. `config/` is backed up nightly by the server
itself, to the local disk and off-site. `bin/verify-host.sh` runs hourly and writes the MOTD, which
is how you learn an update is waiting or a backup has gone stale.
