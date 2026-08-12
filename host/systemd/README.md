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
ln -sf /var/media-stack/host/systemd/media-stack-promote.service ~/.config/systemd/user/
ln -sf /var/media-stack/host/systemd/media-stack-promote.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now media-stack-promote.timer
```

After that a `git pull` deploys changes to these units the same way it does for quadlets — they are
symlinks, so there is no copy step. Only `daemon-reload` is needed.

| Unit | What it does |
|---|---|
| `media-stack-promote` | Moves media that Tdarr has both transcoded **and** health-checked from `library/queued/<type>` into `library/transcoded/<type>`, which is the only place Jellyfin reads. It calls Radarr's and Sonarr's editor endpoints with `moveFiles=true` so the applications move their own files and never lose track of them. See `bin/promote-transcoded.py`. |

```bash
systemctl --user list-timers media-stack-promote.timer
journalctl --user -u media-stack-promote -n 50
/var/media-stack/bin/promote-transcoded.py --dry-run     # safe, changes nothing
```
