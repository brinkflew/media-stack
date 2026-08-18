# Scripts

**Which machine a script runs on is the first thing to know about it**, and `bin/` mixes both sides.
Each script says so in its own header; this is the table.

The split is not arbitrary. Anything holding a credential the server must not have runs on the
workstation, and anything that has to outlive the machine it is talking about cannot run on it.

| Script | Runs on | What it does |
|---|---|---|
| `backup-server.sh` | **server** | Backs up `config/` to `/var/backups/home-server`, then `restic copy` off-site with the append-only key. Nightly, from `home-server-backup.timer`. This is the backup that actually happens. |
| `snapshot-databases.sh` | **server** | Consistent SQLite snapshots through the backup API, found by magic bytes rather than extension. Called by the two backup scripts; little reason to run by hand. |
| `verify-host.sh` | **server** | The health battery, the MOTD, and `/var/lib/home-server/status.json`. Hourly, from `home-server-verify.timer`. `--json` prints the findings machine-readably; `--greenboot` drops every container check and emits no JSON. |
| `collect-metrics.py` | **server** | Every 30 seconds, the numbers no container can honestly measure here: host filesystems and network, the cgroup detail that separates a container holding cold page cache from a starved one, GPU encoder utilisation, sensors, SMART, `status.json` as series, and what the applications think is happening. Writes Prometheus exposition format into node-exporter's textfile directory rather than pushing, because Prometheus pulls. `--print` shows what it produces without writing; `--slow` forces the 5-minute tier; `--source <name>` runs one. Also writes the dashboard's two JSON documents - `activity.json` every 30s and `library.json` every 5 minutes - into `${DOCKER_VOLUME_CACHE}/dashboard/`, because titles cannot be Prometheus labels. |
| `promote-transcoded.py` | **server** | Tells Radarr and Sonarr where Tdarr already moved a file. Every 10 minutes. Never moves media itself. |
| `reboot-when-staged.sh` | **server** | The UNattended reboot, hourly 05:00-09:00 on Sundays from `home-server-reboot.timer`. Every check in it is a refusal - it applies a staged deployment only when greenboot is armed to undo it, nothing has been rejected and left unexplained, no backup is running, the host is healthy now and no transcode is running. The one exception is that transcode, which stops being a veto past 14 days staged or 30 days of uptime. `--dry-run` says what it would do; `HOME_SERVER_STATUS_JSON`, `HOME_SERVER_STAGED_AGE_DAYS` and `HOME_SERVER_ENCODER_PCT` make the otherwise-unreachable gates testable. |
| `clear-red-boot.sh` | **server** | Acknowledges a rejected boot, and clears **both** arms of it: `red_boot_at` in `boot-state`, which holds the unattended window, and `boot_counter` in `/boot/grub2/grubenv`, which is what actually decides whether GRUB boots the default or the fallback. Only a green boot clears the second, so it survives every repair in between - clearing only the first left a machine that looked acknowledged and still rolled back on its next reboot. Refuses when nothing is armed; `--dry-run` says what it would clear. |
| `render-env.sh` | **server** | Renders `.env` from `secrets/env.sops.env`. Also runnable on the workstation. |
| `render-template.py` | **server** | Substitutes `${VAR}` from `.env` into a tracked config template, atomically and 0600. From an `ExecStartPre=` on `ntfy`, `alertmanager` and `ntfy-alertmanager` - the three containers that read a config file and substitute nothing in it. It refuses on an unset variable rather than writing an empty one, because an empty password in a rendered config is not a startup failure, it is a service that authenticates nobody. `--check` names the variables a template needs. |
| `render-jellyfin-branding.py` | **server** | Puts `apps/jellyfin/custom.css` into Jellyfin's `branding.xml`. From an `ExecStartPre=` on `jellyfin.container`. |
| `render-jellyfin-encoding.py` | **server** | Puts `apps/jellyfin/encoding.conf` into Jellyfin's `encoding.xml`, one named element at a time. Never creates the document. From a second `ExecStartPre=` on `jellyfin.container`. |
| `verify-media.sh` | **server** | Does a library file's keyframe grid survive Jellyfin's HLS stream-copy path? Samples three 120s windows and FAILS on any keyframe interval below the 6s segment length, which is the condition that makes browser playback drift. `--library` sweeps, `--full` scans one file exhaustively. |
| `backup-config.sh` | **workstation** | Pulls `config/` into `~/backups/home-server`. The third copy: different machine, different password. Not load-bearing for freshness any more. |
| `backup-offsite.sh` | **workstation** | Copies to Scaleway with the **admin** key, and prunes. The server cannot do this and must not be able to. |
| `verify-restore.sh` | **workstation** | Restores the latest snapshot to a scratch directory and asserts what came out. A backup is not proven until this passes. |
| `reboot-host.sh` | **workstation** | The attended reboot. On the workstation because the waiting cannot happen on the machine that is rebooting. |
| `remote-kexec.sh` | **workstation** | Boots the server into a live Fedora CoreOS in RAM. Touches no disk. |
| `remote-install.sh` | **workstation** | Writes uCore over `nvme0n1`. Irreversible. See `host/RUNBOOK.md` before running it. |
| `lint-repo.sh` | **either** | ASCII, executable bits, shellcheck, quadlet dry-run. |

**`lint-repo.sh` needs `shellcheck`, and SKIPS rather than FAILS without it** - so a machine that
does not have it reports `all checks passed` having never looked at a line of shell. That is
deliberate, because the script has to stay runnable on the server, where `/usr` is read-only. It
also means the workstation is the only place the check really happens, and it went unnoticed there
until 2026-08-14: the leg had never run at all. Install it the same way as `sops` and `age`, as a
static binary in `~/.local/bin`:

```bash
curl -sfL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz \
  | tar -xJ -C /tmp && install -m 755 /tmp/shellcheck-v0.10.0/shellcheck ~/.local/bin/
```

**Two credentials never cross the boundary**, and that is the point of the split:

- The **admin** Scaleway key and the workstation's restic passwords stay on the workstation. They
  are what can delete backups, so putting them on the server would undo the reason the server's own
  key is append-only.
- The server's own age private key decrypts `secrets/`, so it holds the **append-only** key and the
  repository passwords - enough to write a backup and read one, never enough to destroy history.

## Deploying the metrics change of 2026-08-17 needs one manual run

`home_server_jellyfin_sessions` moved from the 5-minute tier to the 30-second one, so it moved from
`home-server-slow.prom` to `home-server.prom`. node-exporter concatenates every `*.prom`, and the
slow file is deliberately left alone on a fast-only tick - so on the first run after a `git pull`
the new fast file and the *previous* slow file both carry that metric with the same labels, which is
a genuine duplicate and fails the whole textfile scrape until the slow tier next runs.

It heals itself within five minutes. To skip the gap entirely, force one full run after pulling:

```bash
./bin/collect-metrics.py --slow          # rewrites BOTH files with the new layout
podman exec prometheus wget -q -O - \
  'http://127.0.0.1:9090/api/v1/query?query=node_textfile_scrape_error'   # expect 0
```
