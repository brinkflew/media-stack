# Quadlet units

**What is actually running**, since 2026-08-12. These are the unit definitions; the files they
deploy into containers live in `apps/`.

`~/.config/containers/systemd/{common,torrent,media,infra}` on the server are symlinks to these
directories, so a `git pull` plus `systemctl --user daemon-reload` is the entire deploy. Quadlet
flattens the directories, so the split below is for humans; unit names must be unique across all of
them.

Validate without starting anything, which catches syntax errors but **not** unset variables:

```bash
QUADLET_UNIT_DIRS="$PWD/stacks/common:$PWD/stacks/torrent:$PWD/stacks/media:$PWD/stacks/infra" \
  /usr/libexec/podman/quadlet -dryrun -user
```

## Layout

| Directory | Contents |
|---|---|
| `common/` | the seven `.network` units, one per trust boundary |
| `torrent/` | `torrent.pod` and its three members: gluetun, qBittorrent, JOAL |
| `media/` | the media applications |
| `infra/` | ingress, identity and dynamic DNS |

## Things that were not a mechanical translation of the Compose file

The Compose file was removed on 2026-08-14, once the quadlets had run for two days. What follows is
why the translation was not mechanical, which is worth keeping even though the original is gone;
`git log` has the file itself.

**`PUID=0` and `PGID=0`, deliberately.** Under rootless Podman, container UID 1000 maps to a subuid
(`avanserv:100000`), *not* to the host's 1000 that owns `/mnt/media`. Container UID **0** is what
maps to the invoking user. Verified with a throwaway container before any of this was written:
`PUID=0` produced files owned by host `1000:1000`, `PUID=1000` produced `525287:525287`. The
`.env` still says `PUID=1000` because Compose is rootful and needs it - that file serves both
runtimes until Compose is deleted.

**`network_mode: service:gluetun` became a pod.** `Network=` goes on `torrent.pod`; the three
member containers declare `Pod=torrent.pod` and no network of their own. Giving one its own
`Network=` would put it outside the VPN.

**The pod is created with `--exit-policy=continue`, and it must be.** Quadlet's default is `stop`,
which stops the pod as soon as its last container exits - so restarting any member was a trap:
systemd stops the dependants first, gluetun goes last, the exit policy stops the pod,
`torrent-pod.service` sees its infra pid vanish and runs `podman pod rm --force`, and the member
cannot come back because it is `BindsTo=torrent-pod.service`:

```
gluetun.service: Bound to unit torrent-pod.service, but unit isn't active.
```

Measured, not theorised: a plain `systemctl --user restart gluetun` took the whole torrent stack
down and left it there. `podman auto-update` is *not* affected - it is pod-aware and restarts
`torrent-pod.service` - but the ordinary operator action any runbook would tell you to do was
broken.

**qBittorrent and JOAL carry `PartOf=gluetun.service` as well as `Requires=`.** `Requires=`
propagates a stop but *not* a restart, so even with the pod intact they stayed down while gluetun
came back up.

**Health-gated start, which Compose did with `depends_on: condition: service_healthy`.** gluetun
sets `Notify=healthy`, so systemd does not consider it started until its healthcheck passes;
qBittorrent and JOAL then `Requires=`/`After=` it. This matters more here than under Compose: pod
members share the infra container's network namespace, which has a working default route out
through the bridge *before* gluetun builds the tunnel and the killswitch. Starting a downloader
into that window would leak traffic around the VPN.

**Images follow tags, and `podman-auto-update` runs nightly.** They were digest-pinned, and the
pinning was abandoned on 2026-08-13 because nothing maintained it: thirteen of eighteen images were
three months old and gluetun's tag had moved twice. A pin with no update path is worse than a tag -
the same staleness, plus the appearance of deliberateness. What was given up is reproducibility and
`git revert` as the rollback; what was gained is security patches arriving without anyone acting.

**Where upstream publishes a major-version tag, it is used.** That is the only remaining control
over what lands unattended, and it costs nothing in currency. Three were checked rather than assumed
and all three were wrong at first guess:

| Unit | Tag | Why not `:latest` |
|---|---|---|
| `qbittorrent` | `:libtorrentv1` | `:latest` is a libtorrent **2.0** build; the pin was 1.2. libtorrent 2.0 memory-maps torrent data, and this host's media disk loses 45% of its throughput to a second concurrent reader. |
| `pocket-id` | `:v2` | `:v1` is the 1.x line - it would have **downgraded** the service that gates sign-on. |
| `tinyauth` | `:v5` | `:v3` does not exist; v5.1.3 is what runs. |
| `gluetun` | `:v3` | It is the kill-switch. A v4 overnight is not worth it. |
| `prowlarr` | `:develop` | Where it was before pinning. Moving it to the release branch would be a downgrade. |

**`Notify=healthy` is what makes the rollback real, and without it the rollback is decorative.**
`podman auto-update` restores the previous image only if the unit fails to **start**, and by default
systemd calls a container started the moment it is running - so an image that comes up and is broken
passes. Every service with a `HealthCmd=` therefore carries `Notify=healthy`, which binds the unit's
start to its healthcheck. **Proven, not assumed**: a test unit was pointed at a deliberately broken
image, `podman auto-update` was run, and the journal shows the failed start followed by the previous
image being pulled back and started.

**Each also carries a `HealthStartupCmd=` at a 5s interval**, and that is not cosmetic. With only
the 60s `HealthInterval` the first probe does not run until t=60s, so every unit took ~65s to start -
about 15 minutes across a full sequential update run. The startup check brought the same restart to
20s. The 60s steady-state interval is untouched, because it used to be what kept podman's ~1.5 KB
`health_status` events out of the journal.

**That is no longer the reason, and the interval is no longer the lever.** Cutting 30s to 60s halved
the events and left them at **47.3% of all journal bytes** - 34,738 a day at 3.8 KB each, every one
saying `healthy`. They are off entirely now, via `healthcheck_events = false` in
`host/containers/containers.conf`, which drops `health_status` and keeps every lifecycle event.
So **pick a health interval for how fast you want a failure noticed**, not to protect the journal.
The cost of turning them off, and why `Notify=healthy` still makes auto-update's rollback fire, is
in CLAUDE.md under "Logs and status".

**`duckdns` and `unpackerr` define no healthcheck**, so they get no rollback beyond "did it crash
immediately". That is accepted, not overlooked.

**Caddy is built here, so it takes `AutoUpdate=local`** - and `local` policy notices a new image
without ever *producing* one, while a `.build` unit only runs when its image is absent. Left alone,
the one built image would have been the only thing in the stack that never updated.
`home-server-caddy-build.timer` rebuilds it weekly, and `caddy.build` carries `Pull=newer` because
podman build's default pull policy is `missing` - it would otherwise reuse a stale local `caddy:2`
for ever while succeeding in four seconds.

**Old images survive the nightly prune.** The shipped `podman-auto-update.service` runs
`podman image prune -f` afterwards, but a superseded image keeps its repository digest and so is not
*dangling*; only `prune -a` would remove it. So the manual rollback below keeps working:

```bash
podman images                                          # find the previous image ID
podman tag <old-id> lscr.io/linuxserver/sonarr:latest
systemctl --user restart sonarr
```

**SELinux labels, which the Compose file has none of** because the current host does not enforce.
Per-service config directories get `:Z` (private relabel). Shared directories get `:z`. The media
mount gets **neither**: it is 7 TB and `:z` would trigger a recursive relabel of the whole disk on
every start. Its label is set once at mount time - see `host/butane/`.

**`Environment=KEY=${KEY}` with `EnvironmentFile=` in `[Service]`.** Quadlet passes `ExecStart`
through to systemd, which expands `${KEY}` from the unit environment, so the same rendered `.env`
parameterises both runtimes. Two consequences worth knowing: an undefined variable expands to an
empty string **silently**, with none of the loudness of Compose's `${VAR:?err}`; and a value
containing whitespace would be split into separate arguments. Neither applies to any value in use,
but both are traps when adding one.
