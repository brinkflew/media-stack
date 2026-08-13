# media-stack

A self-hosted server, defined declaratively. Media-focused today, deliberately widening.

Everything reaches the outside world through one reverse proxy on ports 80 and 443, behind passkey
single sign-on. There are no passwords to phish: authentication is a WebAuthn signature from a
device you already carry.

## What is in here

| Path | What it is |
|---|---|
| `docker-compose.yaml` | the stack as it runs today |
| `stacks/` | the Podman quadlet units that replace it — written, validated, not yet deployed |
| `host/butane/` | the host itself, as an Ignition config |
| `host/RUNBOOK.md` | the migration procedure, start to finish |
| `ingress/` | the Caddyfile and the Caddy build with the Gandi DNS module |
| `secrets/` | every credential, encrypted with sops+age |
| `bin/` | deploy and migration scripts — env rendering, backups, the remote install |

## Shape of it

Seven container networks, one per trust boundary, so a compromised container reaches only what it
genuinely needs to talk to. The proxy is the only thing that joins more than one. The torrent
client and the tracker announcer have no network stack of their own — they live inside the VPN
container's namespace, which makes the kill-switch structural rather than a firewall rule someone
has to maintain.

Certificates are issued per hostname on demand over DNS-01, so adding a service is a DNS record and
a block in the Caddyfile, and a hostname nobody has configured simply fails the TLS handshake.

`CLAUDE.md` is the real documentation — architecture, the reasoning behind each decision, and the
things that were learned the hard way and should not be rediscovered.

## Direction

Runs on an immutable [uCore](https://github.com/ublue-os/ucore) host with rootless Podman quadlets,
migrated from Fedora 37 and Docker Compose on 2026-08-12.

---

**Both halves update themselves, on separate tracks.** Containers follow tags and are updated
nightly by `podman-auto-update`, which restores the previous image if a unit fails to start. The OS
stages a new deployment nightly and **never reboots on its own** — the machine has no console and no
BMC, so applying it is a deliberate act. `bin/verify-host.sh` runs hourly and writes the MOTD, which
is how you learn an update is waiting.
