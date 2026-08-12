# Host provisioning

Butane source for the uCore install (Stage 2). `ucore.bu` is transpiled to Ignition JSON and fed to
`coreos-installer`; the machine is then declaratively defined by this file rather than by whatever
was typed into it over its lifetime.

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict < ucore.bu > ucore.ign
```

**The install target is `nvme0n1`. `sda` is the 8 TB media disk and must not be touched** — it is
the one thing here that is not reproducible from this repository, and it holds the library.

Four of the entries in `ucore.bu` exist because a rootless Podman stack does not work without them,
and each fails in a way that does not obviously point at its cause:

| Entry | Without it |
|---|---|
| `net.ipv4.ip_unprivileged_port_start=80` | Caddy cannot bind 80/443 and nothing is reachable |
| udev rule for `/dev/net/tun` | gluetun cannot build the tunnel, so both downloaders stay down |
| `context=` on the `/mnt/media` mount | either SELinux denies every media read, or a `:z` relabels 8 TB |
| `linger` for the service user | every container stops at logout and does not start at boot |

`ucore.bu` is written but **not yet applied** — it describes the machine the migration will create,
not the one running today.
