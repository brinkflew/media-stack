# Host systemd user units

Plain `systemd --user` units, as opposed to the quadlets in `stacks/`. Anything here runs **on the
host** rather than in a container, which is the point: `podman exec` reaches into any container
whatever the network topology says, so a host-side unit can talk to services that are deliberately
unable to talk to each other.

`~/.config/systemd/user/` is a **second symlink root**, alongside the
`~/.config/containers/systemd/{common,torrent,media,infra}` ones that point at `stacks/`. It does not
exist on a fresh host, so it needs creating once:

```bash
mkdir -p ~/.config/systemd/user
for u in /var/home-server/host/systemd/*.service /var/home-server/host/systemd/*.timer; do
  ln -sf "$u" ~/.config/systemd/user/
done
for d in /var/home-server/host/systemd/*.service.d; do
  ln -sfn "$d" ~/.config/systemd/user/
done
systemctl --user daemon-reload
systemctl --user enable --now home-server-promote.timer home-server-verify.timer \
                              home-server-caddy-build.timer home-server-backup.timer \
                              home-server-reboot.timer home-server-metrics.timer \
                              home-server-dashboard-build.timer home-server-seeding.timer \
                              home-server-search.timer
```

**The loop is a glob rather than a list on purpose.** It used to name the four files it knew about,
and `home-server-caddy-build` was added later and never appended - so it was enabled on the server
and absent from the documented setup, which means a rebuild from this file would have produced a
host where Caddy silently never updated. A glob cannot drift; the `enable` line still can, so it
names every timer explicitly.

**Adding a unit here means adding it to that loop.** Individual files are symlinked, not the
directory - unlike `~/.config/containers/systemd/{common,torrent,media,infra}`, which point at
whole directories in `stacks/` and so pick up new files for free. A unit added here and not
symlinked is invisible, and nothing complains.

**A `*.service.d/` directory is the one exception, and it is symlinked WHOLE**, which is why there
is a second loop. These are drop-ins over units this repository does not own - podman's own
`podman-auto-update.service` today - so there is no file of ours to symlink beside them, and
systemd resolves a symlinked drop-in directory happily. Linking the directory rather than each
`.conf` inside it means a second drop-in is picked up for free, the way `stacks/` already works.
Note `ln -sfn`: without `-n`, a re-run follows the existing symlink and nests the target inside
itself.

**Drop-ins over a USER unit may be symlinks into the checkout; over a SYSTEM unit they may not.**
`systemd --user` for uid 1000 runs as `unconfined_t` and reads `var_t` fine, which is why every
quadlet here is already a symlink. PID 1 cannot, so `host/journald/` and greenboot's ordering
drop-in are duplicated into `host/butane/ucore.bu` instead - and the failure there is silent, with
`systemctl cat` printing a file that does not apply and no AVC logged. See
`host/greenboot/README.md`.

**Assert a drop-in by its effect, never by its presence**, for that same reason:

```bash
systemctl --user show podman-auto-update.service -p ExecStartPost
```

After that a `git pull` deploys changes to these units the same way it does for quadlets - they are
symlinks, so there is no copy step. Only `daemon-reload` is needed.

| Unit | What it does |
|---|---|
| `home-server-promote` | Moves media that Tdarr has both transcoded **and** health-checked from `library/queued/<type>` into `library/transcoded/<type>`, which is the only place Jellyfin reads. It calls Radarr's and Sonarr's editor endpoints with `moveFiles=false` plus a rescan, so the applications are told where the file went and never lose track of it. See `bin/promote-transcoded.py`. |
| `home-server-verify` | Runs the host health battery hourly and writes **two** files: `/run/motd.d/40-home-server.motd`, so a staged OS update, a failed unit, a stale CDI spec or a backup that has stopped running is the first thing an ssh session shows; and `/var/lib/home-server/status.json`, the same findings keyed by a stable id for a dashboard to read. The MOTD is on tmpfs and dies with the boot - the JSON does not, which is what finally gives this unit a durable record of its own last success. See `bin/verify-host.sh` and `docs/observability.md`. |
| `home-server-caddy-build` | Rebuilds the Caddy image weekly. Caddy is one of two images built here rather than pulled, and `AutoUpdate=local` notices a new image without producing one - so without this it would never update. See `apps/caddy/Dockerfile`. |
| `home-server-dashboard-build` | Rebuilds the dashboard image nightly, and **this one is also the deploy path**. Its content comes from the checkout rather than from an upstream release, and `dist/` is not committed - so a `git pull` that changes `apps/dashboard/src/` deploys nothing at all until this runs, silently, while every other kind of change in the same commit takes effect on `daemon-reload`. Nightly rather than weekly for that reason. Run it by hand to see a change now. See `apps/dashboard/README.md`. |
| `home-server-reboot` | Applies a staged OS deployment, hourly 05:00-09:00 on Sundays - but only if greenboot is armed to undo it, no deployment has been rejected and left unexplained, no backup is running, the host is healthy now and nothing is mid-transcode. Every check is a refusal and doing nothing is the default; the one exception is the encoder, which stops being a veto past 14 days staged or 30 days of uptime. Five attempts rather than one because that refusal is transient. See `bin/reboot-when-staged.sh`. |
| `home-server-metrics` | Collects, every 30 seconds, the numbers no container can honestly measure here: host filesystems (node-exporter's collector reads `/proc/1/mountinfo`, which no rootless container may), host network (`/proc/net` resolves in the reader's namespace), and the cgroup memory detail that separates a container holding cold page cache from one that is actually starved. It writes Prometheus exposition format into node-exporter's textfile directory rather than pushing, because Prometheus pulls - which also buys `node_textfile_mtime_seconds`, dating the file from outside the collector. See `bin/collect-metrics.py`. |
| `home-server-backup` | Backs up `config/` nightly at 03:00, to `/var/backups/home-server` and then off-site by `restic copy`. This is the backup that actually happens; the workstation's `bin/backup-config.sh` is a third copy taken when someone is home. See `bin/backup-server.sh`. |
| `home-server-seeding` | Enforces the one part of the seeding policy qBittorrent cannot express: a **72-hour floor** before any torrent may be stopped. Every share limit qBittorrent has is a maximum that triggers an action, so a minimum can only be enforced by withholding those limits - which is all this does. Past 72h a torrent gets ratio 1.5 and a seven-day seeding limit and qBittorrent stops it on whichever lands first; Radarr and Sonarr then delete it and its files, as they already did. It deletes nothing itself, and a stopped timer means nothing is ever reaped rather than things being reaped early. See `bin/apply-seeding-policy.py`. |
| `podman-auto-update.service.d` | **Not a unit of ours - a drop-in over podman's.** It makes the `ExecStartPost=` image prune non-fatal, so a disk reclaim that could be skipped for a night cannot mark the unit that updates eighteen containers as failed. It could and did: on 2026-08-17 and 2026-08-18 `podman auto-update` exited 0, every container updated, and the unit reported failure because the prune hit a leftover build container and exited 125. The condition itself is now measured by `containers.storage_orphans`, which is what makes this a correction and not a silencer. |

```bash
systemctl --user list-timers home-server-promote.timer home-server-verify.timer
journalctl --user -u home-server-promote -n 50
/var/home-server/bin/promote-transcoded.py --dry-run     # safe, changes nothing
/var/home-server/bin/apply-seeding-policy.py --dry-run --verbose   # ditto
/var/home-server/bin/verify-host.sh                      # read-only apart from the MOTD
/var/home-server/bin/verify-host.sh --routes             # also walks the public routes
```
