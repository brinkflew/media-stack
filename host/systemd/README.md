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
for u in media-stack-promote.service media-stack-promote.timer \
         media-stack-verify.service  media-stack-verify.timer; do
  ln -sf "/var/media-stack/host/systemd/$u" ~/.config/systemd/user/
done
systemctl --user daemon-reload
systemctl --user enable --now media-stack-promote.timer media-stack-verify.timer
```

**Adding a unit here means adding it to that loop.** Individual files are symlinked, not the
directory — unlike `~/.config/containers/systemd/{common,torrent,media,infra}`, which point at
whole directories in `stacks/` and so pick up new files for free. A unit added here and not
symlinked is invisible, and nothing complains.

After that a `git pull` deploys changes to these units the same way it does for quadlets — they are
symlinks, so there is no copy step. Only `daemon-reload` is needed.

| Unit | What it does |
|---|---|
| `media-stack-promote` | Moves media that Tdarr has both transcoded **and** health-checked from `library/queued/<type>` into `library/transcoded/<type>`, which is the only place Jellyfin reads. It calls Radarr's and Sonarr's editor endpoints with `moveFiles=false` plus a rescan, so the applications are told where the file went and never lose track of it. See `bin/promote-transcoded.py`. |
| `media-stack-verify` | Runs the host health battery hourly and writes `/run/motd.d/40-media-stack.motd`, so a staged OS update, a failed unit or a stale CDI spec is the first thing an ssh session shows. See `bin/verify-host.sh`. |

```bash
systemctl --user list-timers media-stack-promote.timer media-stack-verify.timer
journalctl --user -u media-stack-promote -n 50
/var/media-stack/bin/promote-transcoded.py --dry-run     # safe, changes nothing
/var/media-stack/bin/verify-host.sh                      # read-only apart from the MOTD
/var/media-stack/bin/verify-host.sh --routes             # also walks the public routes
```
