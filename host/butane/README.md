# Host provisioning

Butane source for the uCore install (Stage 2). `ucore.bu` is transpiled to Ignition JSON and fed to
`coreos-installer`; the machine is then declaratively defined by this file rather than by whatever
was typed into it over its lifetime.

**Do not run the install from this file alone - follow [`../RUNBOOK.md`](../RUNBOOK.md).** Ignition
provisions the host, but it cannot restore the age key, the secrets or `config/`, and the order in
which those happen afterwards is what makes the difference between a working stack and a subtly
broken one.

```bash
podman run --rm -i quay.io/coreos/butane:release --pretty --strict < ucore.bu > ucore.ign
```

**The install target is `nvme0n1`. `sda` is the 8 TB media disk and must not be touched** - it is
the one thing here that is not reproducible from this repository, and it holds the library.

Four of the entries in `ucore.bu` exist because a rootless Podman stack does not work without them,
and each fails in a way that does not obviously point at its cause:

| Entry | Without it |
|---|---|
| `net.ipv4.ip_unprivileged_port_start=80` | Caddy cannot bind 80/443 and nothing is reachable |
| udev rule for `/dev/net/tun` | gluetun cannot build the tunnel, so both downloaders stay down |
| `context=` on the `/mnt/media` mount | either SELinux denies every media read, or a `:z` relabels 8 TB |
| `linger` for the service user | every container stops at logout and does not start at boot |

**`ucore.bu` was applied on 2026-08-12, and Ignition runs only once.** So it now describes the
machine as first created, not necessarily as it stands: editing it changes nothing on the running
host. Anything added here must also be applied by hand, and anything applied by hand must be added
here, or the next reinstall loses it.

The applied config predates two of the units below - `firewall-stack-ports.service` and
`selinux-container-devices.service` were created by hand on 2026-08-13 to close that gap, along with
`/etc/rpm-ostreed.conf` and the updater masks.

## `live.bu`

A second, much smaller config for the **live** environment that `bin/remote-kexec.sh` boots into.
It authorises SSH and nothing else; the live system exists only to be logged into so that
`coreos-installer` can be run from something that is not the disk being written.

Its networking deliberately does **not** live here - it comes from kernel arguments, so dracut
applies it in the initramfs rather than NetworkManager applying it after switch-root. On a machine
with no console, an ordering bug there is indistinguishable from one that never booted.
