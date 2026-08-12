# Quadlet units

The Podman replacement for `docker-compose.yaml`. **Not yet deployed** — the server runs Podman
4.4.2, which predates `.pod` quadlets (they need ≥ 5.0), so these are validated on a workstation
until the uCore reinstall. `docker-compose.yaml` stays at the repo root and remains the thing that
is actually running.

```bash
QUADLET_UNIT_DIRS="$PWD/stacks/common:$PWD/stacks/torrent:$PWD/stacks/media:$PWD/stacks/infra" \
  /usr/libexec/podman/quadlet -dryrun -user
```

Deployed by symlinking or copying every unit into `~/.config/containers/systemd/`, then
`systemctl --user daemon-reload && systemctl --user start <name>.service`. Quadlet flattens the
directories, so the split below is for humans; unit names must be unique across all of them.

## Layout

| Directory | Contents |
|---|---|
| `common/` | the seven `.network` units, one per trust boundary |
| `torrent/` | `torrent.pod` and its three members — gluetun, qBittorrent, JOAL |
| `media/` | the media applications |
| `infra/` | ingress, identity and dynamic DNS |

## Things that are not a mechanical translation of the Compose file

**`PUID=0` and `PGID=0`, deliberately.** Under rootless Podman, container UID 1000 maps to a subuid
(`avanserv:100000`), *not* to the host's 1000 that owns `/mnt/media`. Container UID **0** is what
maps to the invoking user. Verified with a throwaway container before any of this was written:
`PUID=0` produced files owned by host `1000:1000`, `PUID=1000` produced `525287:525287`. The
`.env` still says `PUID=1000` because Compose is rootful and needs it — that file serves both
runtimes until Compose is deleted.

**`network_mode: service:gluetun` became a pod.** `Network=` goes on `torrent.pod`; the three
member containers declare `Pod=torrent.pod` and no network of their own. Giving one its own
`Network=` would put it outside the VPN.

**Health-gated start, which Compose did with `depends_on: condition: service_healthy`.** gluetun
sets `Notify=healthy`, so systemd does not consider it started until its healthcheck passes;
qBittorrent and JOAL then `Requires=`/`After=` it. This matters more here than under Compose: pod
members share the infra container's network namespace, which has a working default route out
through the bridge *before* gluetun builds the tunnel and the killswitch. Starting a downloader
into that window would leak traffic around the VPN.

**Images are pinned by digest**, taken from what was actually running and verified — not from
whatever `:latest` resolved to that day. That makes a rollback a `git revert`. Updating is
deliberate: change the digest, commit, restart. `podman-auto-update` is *not* enabled, because it
follows tags and would quietly undo the pinning.

**SELinux labels, which the Compose file has none of** because the current host does not enforce.
Per-service config directories get `:Z` (private relabel). Shared directories get `:z`. The media
mount gets **neither**: it is 7 TB and `:z` would trigger a recursive relabel of the whole disk on
every start. Its label is set once at mount time — see `host/butane/`.

**`Environment=KEY=${KEY}` with `EnvironmentFile=` in `[Service]`.** Quadlet passes `ExecStart`
through to systemd, which expands `${KEY}` from the unit environment, so the same rendered `.env`
parameterises both runtimes. Two consequences worth knowing: an undefined variable expands to an
empty string **silently**, with none of the loudness of Compose's `${VAR:?err}`; and a value
containing whitespace would be split into separate arguments. Neither applies to any value in use,
but both are traps when adding one.
