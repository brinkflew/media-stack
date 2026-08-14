# Scripts

**Which machine a script runs on is the first thing to know about it**, and `bin/` mixes both sides.
Each script says so in its own header; this is the table.

The split is not arbitrary. Anything holding a credential the server must not have runs on the
workstation, and anything that has to outlive the machine it is talking about cannot run on it.

| Script | Runs on | What it does |
|---|---|---|
| `backup-server.sh` | **server** | Backs up `config/` to `/var/backups/media-stack`, then `restic copy` off-site with the append-only key. Nightly, from `media-stack-backup.timer`. This is the backup that actually happens. |
| `snapshot-databases.sh` | **server** | Consistent SQLite snapshots through the backup API, found by magic bytes rather than extension. Called by the two backup scripts; little reason to run by hand. |
| `verify-host.sh` | **server** | The health battery, and the MOTD. Hourly, from `media-stack-verify.timer`. `--greenboot` drops every container check. |
| `promote-transcoded.py` | **server** | Tells Radarr and Sonarr where Tdarr already moved a file. Every 10 minutes. Never moves media itself. |
| `render-env.sh` | **server** | Renders `.env` from `secrets/env.sops.env`. Also runnable on the workstation. |
| `render-jellyfin-branding.py` | **server** | Puts `apps/jellyfin/custom.css` into Jellyfin's `branding.xml`. From an `ExecStartPre=` on `jellyfin.container`. |
| `backup-config.sh` | **workstation** | Pulls `config/` into `~/backups/media-stack`. The third copy: different machine, different password. Not load-bearing for freshness any more. |
| `backup-offsite.sh` | **workstation** | Copies to Scaleway with the **admin** key, and prunes. The server cannot do this and must not be able to. |
| `verify-restore.sh` | **workstation** | Restores the latest snapshot to a scratch directory and asserts what came out. A backup is not proven until this passes. |
| `reboot-host.sh` | **workstation** | The attended reboot. On the workstation because the waiting cannot happen on the machine that is rebooting. |
| `remote-kexec.sh` | **workstation** | Boots the server into a live Fedora CoreOS in RAM. Touches no disk. |
| `remote-install.sh` | **workstation** | Writes uCore over `nvme0n1`. Irreversible. See `host/RUNBOOK.md` before running it. |
| `lint-repo.sh` | **either** | ASCII, executable bits, shellcheck, quadlet dry-run. |

**Two credentials never cross the boundary**, and that is the point of the split:

- The **admin** Scaleway key and the workstation's restic passwords stay on the workstation. They
  are what can delete backups, so putting them on the server would undo the reason the server's own
  key is append-only.
- The server's own age private key decrypts `secrets/`, so it holds the **append-only** key and the
  repository passwords - enough to write a backup and read one, never enough to destroy history.
