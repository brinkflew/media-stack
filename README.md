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
| `bin/` | `render-env.sh`, which turns `secrets/` into a usable `.env` |

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

Migrating to an immutable [uCore](https://github.com/ublue-os/ucore) host running rootless Podman
quadlets. Ingress, network segmentation and secrets are already done on the current stack,
deliberately ahead of the reinstall, so that the least recoverable step changes only the OS.

---

Currently running on Fedora 37, kernel 6.1 — which is exactly why it is being replaced.
