# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-hosted server stack, currently media-focused, defined as rootless Podman quadlets.
The scope is deliberately widening beyond media - prefer changes that generalise over ones that
assume the stack is only Sonarr/Radarr/Jellyfin.

| Path | What it is |
|---|---|
| `stacks/` | **what is actually running.** Rootless Podman quadlets. Change these to change the server. |
| `apps/` | **what those units deploy into containers.** One directory per service. |
| `host/butane/` | the Ignition config that defines the host itself - applied |
| `host/systemd/` | plain systemd units that run on the host rather than in a container |
| `secrets/` | every credential, sops+age encrypted; `.env` is rendered from it |

**One rule holds those two apart: unit definitions in `stacks/`, the files they deploy in `apps/`.**
A payload gets into its container by an `ExecStartPre=` copy on that service's quadlet, so git stays
authoritative and nothing has to be tracked inside the gitignored `config/` tree. Four services use
it today: `apps/caddy/` (the Caddyfile, bind-mounted rather than copied), `apps/tdarr/plugins/`,
`apps/sonarr/scripts/` and `apps/jellyfin/custom.css`.

**The migration happened on 2026-08-12.** The server runs uCore with rootless Podman quadlets.
`docker-compose.yaml` was kept for reference until 2026-08-14 and is now deleted: the two runtimes
had diverged (Compose still defined a `tdarr-node-02` that has no quadlet, and had no `bazarr`,
which does), so "it documents a configuration that demonstrably worked" had stopped being true.
`git log` has it if it is ever wanted.

**The service user is `core`, uid 1000** - not `avanserv`, which no longer exists. Fedora CoreOS
ships `core` at uid 1000 and Ignition cannot create a second user there, so the account that already
held the uid was adopted. The filesystem stores uids, so `/mnt/media` and `config/` needed no chown.

There is no application code here: no build, no lint, no test suite. The unit of work is a
service definition, and the verification loop is "does the container come up and stay healthy".

## Deployment model

This repo is the source of truth. The server runs a **git checkout of it** at `/var/home-server`,
reachable over passwordless SSH as `home` (WAN, via the router's `9122 -> 22` forward) or
`home.local` (direct, `192.168.0.100`). **Prefer `home.local`** - the WAN route depends on NAT
hairpinning and on the forward still pointing at the right address.

**The same applies in the BROWSER, and it costs more than it does over SSH.** Every public hostname
here is a CNAME to `avanserv.duckdns.org`, which resolves to the server's own WAN address
(`91.86.121.124`), so a LAN machine loading `watch.avanserv.com` sends every request out through the
router and back in through NAT loopback. Measured against `/web/index.html`: **12-16 ms direct
against 74-79 ms proxied, about 5x per request** - and a Jellyfin page is ~29 JS bundles plus 30-60
images, so a full load went 283-684 ms direct against 898-1612 ms proxied. Nothing is misconfigured;
the packets are simply taking a long way round. The fix is split-horizon DNS pointing the public
names at `192.168.0.100` for LAN clients, which keeps TLS, the certificate and sign-on working
unchanged because Caddy listens on that address too.

`~/.config/containers/systemd/{common,torrent,media,infra}` are symlinks into `stacks/`, so
`git pull && systemctl --user daemon-reload` is the entire deploy - there is no copy step.

**`~/.config/systemd/user/` is a second symlink root**, pointing at `host/systemd/`. It holds plain
systemd units rather than quadlets - things that run *on the host* rather than in a container, which
is how they reach services that are deliberately unable to reach each other. It does not exist on a
fresh host and is not created by Ignition; see `host/systemd/README.md` for the one-time setup.

**Containers run `PUID=0`/`PGID=0`, which is not a privilege escalation.** Rootless Podman maps
container UID 0 to the invoking user, `core` (uid 1000), which is what owns `/mnt/media` and
`config/`. A container "running as root" is uid 1000 on the host. Anything *other* than 0 maps into
the subuid range (`core:100000:65536`) and cannot read the data.

```bash
ssh home.local 'cd /var/home-server && git status --short'   # ALWAYS do this before editing
```

**The remote has drifted from git before**, and it is easy to cause. Reconcile any drift into git
*before* making changes, or your edits will be silently clobbered or will clobber someone else's.

**Change files here, commit, then `git pull` on the server - never edit them over SSH.** Editing
the checkout directly recreates the drift, and the next `git pull` refuses to apply with "local
changes would be overwritten". The only thing that legitimately differs on the server is the
runtime state under `config/`.

## Secrets

**`.env` is generated, not edited.** It is rendered from `secrets/env.sops.env` - every value
encrypted with sops+age, committed to this public repo, which is what finally puts the credentials
under version control and into a backup. Editing `.env` in place works right up until the next
render silently discards it.

```bash
sops secrets/env.sops.env      # decrypts into $EDITOR, re-encrypts on save
git commit && git push          # then on the server:
ssh home.local 'cd /var/home-server && git pull && ./bin/render-env.sh &&
                systemctl --user daemon-reload && systemctl --user restart <affected units>'
```

- **Two age recipients**, workstation and server, so losing either machine does not lock you out.
  Their private keys are at `~/.config/sops/age/keys.txt` and belong in a password manager - they
  are the one thing here that cannot be regenerated. Adding a third recipient means editing
  `.sops.yaml` *and* running `sops updatekeys secrets/env.sops.env`; existing files are not
  re-encrypted for you.
- **The creation rule is matched against the file sops reads, not the one it writes.** Seeding
  `secrets/env.sops.env` from `.env` therefore matches as `.env`, which is why `.sops.yaml` covers
  both names. Without that it fails with an unhelpful "no matching creation rules found".
- **Variable names stay legible and empty values stay unencrypted.** That is deliberate: a diff
  should still show which credential changed. It does mean the file publishes the shape of the
  stack, which `stacks/` and `.env.sample` already do in full.
- **sops' dotenv format does not preserve every comment**, so a rendered `.env` is barer than a
  hand-written one. `.env.sample` is the documentation; **update it whenever you add a variable**,
  or the next person gets `variable is not set` from `${VAR:?err}`.
- `sops` and `age` are static binaries in `~/.local/bin` on both machines, not system packages -
  `/usr/local` needs a sudo password on the server and this does not. That directory is absent from
  a non-interactive ssh `PATH`, which is why `render-env.sh` sets it itself.

## Backups

`config/` is the only part of this system that cannot be rebuilt from git. It is 5.6 GB on
`nvme0n1p4` - the same disk the OS and the checkout live on, and the one a uCore reinstall wipes.

**The server backs itself up, nightly, and that is the important change.** It used to run only from
the workstation, on demand, which meant the backup happened as often as someone was at home: on
2026-08-14 both repositories were two days stale and everything since the migration - the four-library
Tdarr setup, the per-library audio whitelists, the Radarr `[VO]` rescoring, the new root folders,
passkeys, watch state - existed in exactly one place.

```bash
systemctl --user start home-server-backup     # on the server; the timer runs it at 03:00
./bin/verify-restore.sh                       # from the WORKSTATION: does it actually restore?
```

| Copy | Where | Written by | Protects against |
|---|---|---|---|
| local | `/var/backups/home-server` on the server | `bin/backup-server.sh`, nightly | a bad change, a bad restore, an application corrupting its own database |
| off-site | Scaleway `s3.fr-par.scw.cloud/home-server-backup` | the same run, by `restic copy` | the disk, the machine, the building |
| pull | `~/backups/home-server` on the workstation | `bin/backup-config.sh`, when you are home | the server being compromised outright |

**The local copy is on the same disk as `config/` and does not survive it.** That is deliberate -
`/mnt/media` is kept for media - and it is why the off-site leg runs every night rather than
opportunistically. `bin/verify-host.sh` FAILS at 48h for the local copy and 72h for the off-site one.

**The off-site key cannot delete, and that is the whole security argument.** The old design kept
every backup credential off the server, so compromising the server did not reach the backups.
Driving the schedule from the server spends part of that, so what is left has to be enforced rather
than assumed: the Scaleway application key is scoped to `PutObject`/`GetObject`/`ListBucket`, with
`DeleteObject` denied everywhere except the `locks/` prefix restic needs to release its own lock.

```json
{
  "Version": "2023-04-17",
  "Statement": [
    { "Sid": "AdminKeepsFullAccess",
      "Effect": "Allow",
      "Principal": { "SCW": "user_id:<your own user id>" },
      "Action": ["s3:*"],
      "Resource": ["home-server-backup", "home-server-backup/*"] },
    { "Sid": "ServerMayReadAndWrite",
      "Effect": "Allow",
      "Principal": { "SCW": "application_id:<the append-only application>" },
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject"],
      "Resource": ["home-server-backup", "home-server-backup/*"] },
    { "Sid": "ServerMayReleaseItsOwnLocks",
      "Effect": "Allow",
      "Principal": { "SCW": "application_id:<the append-only application>" },
      "Action": ["s3:DeleteObject"],
      "Resource": ["home-server-backup/locks/*"] }
  ]
}
```

**There is no `Deny` statement, and that is the correct shape rather than a shortcut.** Two things
make it so, both of which are easy to get wrong:

- **Anything not explicitly allowed is already denied.** Granting `DeleteObject` only on `locks/*`
  is what makes every other deletion impossible. An explicit `Deny` on `home-server-backup/*` would
  additionally override the `locks/*` allow, because deny always wins - so the "obvious" belt-and-
  braces version breaks `restic copy`, which cannot then release its own lock.
- **`s3:prefix` is a condition key for `ListBucket`, not for `DeleteObject`.** Scoping a delete by
  prefix is done with the resource path, not a condition. A policy written the other way looks
  plausible and silently fails to constrain anything.

**Include your own principal, or you can lock yourself out of the bucket.** A Scaleway bucket policy
takes precedence over the ownership that would otherwise grant you access, and once applied only the
Organization Owner can replace it.

**THE BUCKET POLICY IS ONLY HALF OF IT. Scaleway ANDs the IAM policy with the bucket policy**, and
the application needs an IAM policy of its own or nothing works. This is the step that is easy to
miss, because the bucket policy looks complete and self-contained. The symptom is restic failing
before it does anything at all:

```
Stat(<config/>) failed: Stat: Access Denied.
Fatal: unable to open config file: Stat: Access Denied.
```

That is a *read* of the repository's own `config` object being refused, not a write - so a policy
granting only `ObjectStorageObjectsWrite` produces it, which is the obvious thing to grant something
called "append-only". The two layers do different jobs, and the split is the whole design:

| Layer | What it can express | What it is for here |
|---|---|---|
| IAM policy | which *kinds* of operation, per project. **No prefix scoping.** | making read, write and delete possible at all |
| bucket policy | per-principal, per-*prefix* | narrowing delete to `locks/*` |

The rule therefore needs all four of these, scoped to the project holding the bucket:

| Permission set | Why |
|---|---|
| `ObjectStorageObjectsRead` | read `config`, the indexes and the packs. Without it nothing opens. |
| `ObjectStorageObjectsWrite` | upload packs |
| `ObjectStorageBucketsRead` | list objects under a prefix |
| `ObjectStorageObjectsDelete` | **release its own lock.** `restic copy` locks the destination and cannot finish without deleting that lock afterwards. |

**Granting delete at the IAM layer does not give away the append-only property**, and this is the
part worth understanding rather than pattern-matching. IAM cannot say "delete only under `locks/`";
the bucket policy can, and does. Delete outside `locks/` is denied there by omission. So the
guarantee rests on the bucket policy, which is exactly what the check below exists to prove -
and it is a real check rather than a restatement, because the two layers can disagree.

**Verify the restriction rather than trusting it.** A policy that silently does nothing looks exactly
like one that works, and this one has no `Deny` to eyeball - it relies on an absence. It was verified
by hand once, with the destructive test below, and **is now re-proved every night** by
`bin/backup-server.sh` so that it cannot quietly stop being true.

**The nightly probe is non-destructive, and the trick is that authorization is evaluated before
object existence.** A `DeleteObject` refused by policy returns `403 AccessDenied`; an allowed one
returns `204 No Content`. So the probe writes a 0-byte object outside `locks/`, tries to delete it,
and expects to be refused. It records `offsite_policy_ok_at` in `~/.cache/home-server/backup-state`
**only on a confirmed refusal**, and `bin/verify-host.sh` FAILS when that marker is more than 48h
old - so one unreachable night reads as stale rather than as broken, and a real regression surfaces
on the second. Two details are load-bearing:

- **The write is not optional.** `rclone deletefile` stats the object first, so against a key that
  does not exist it fails at the `HEAD` and never issues the `DELETE` - a probe that passes for ever
  while testing nothing.
- **Only an explicit refusal counts.** Anything else - a timeout, DNS, a 500 - is inconclusive and
  leaves the previous marker alone. A network blip must not read as a broken policy, and a broken
  policy must not be able to hide behind one.

It uses `rclone`, which uCore already ships at `/usr/bin/rclone`, with credentials passed through
`RCLONE_S3_*` rather than argv for the same reason the restic passwords go into files.

**The destructive test still exists and still proves more**, because it exercises the real call
rather than a probe. Keep it for when the policy itself has been edited:

```bash
ssh home.local 'cd /var/home-server && set -a && . .env && set +a &&
  AWS_ACCESS_KEY_ID="$BACKUP_OFFSITE_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$BACKUP_OFFSITE_SECRET_KEY" \
  ~/.local/bin/restic -r "$BACKUP_OFFSITE_REPOSITORY" \
    --password-command "printenv BACKUP_OFFSITE_PASSWORD" \
    forget --keep-last 1 --prune'      # MUST fail with AccessDenied
```

**Note what this costs if the policy is wrong**, because it is not a free test: succeeding means the
key CAN delete, and it will have pruned the off-site repository to one snapshot on its way to telling
you so. That is recoverable - the workstation holds the full chain and `bin/backup-offsite.sh`
re-copies it - and it is worth knowing at a moment you chose rather than during an incident. Note
also that the nightly run exercises the *allowed* half every night: `restic copy` cannot finish
without creating and then deleting a lock under `locks/`.

**Which narrows the sops rule rather than reversing it.** The **append-only** key and the repository
passwords are in `secrets/env.sops.env`, because the server needs them and they cannot destroy
anything. The **admin** key and the workstation's own passwords are not, and must never be: they are
what prunes, and handing them to the server would undo the paragraph above.

**Retention happens on the workstation**, for the same reason. `bin/backup-server.sh` prunes the
local repository and deliberately never touches the off-site one - the calls would 403 anyway - so
without `bin/backup-offsite.sh` being run occasionally the off-site repository grows for ever.
It records `offsite_pruned_at` on the server when it does, and `verify-host.sh` warns after 30 days.

**The off-site repository holds two snapshot chains**, and that is expected rather than a fault. The
server stages at `/var/backups/staging/config` and the workstation at
`~/.cache/home-server/staging/config`; `restic forget` groups by host **and paths**, so the retention
policy applies to each chain separately - 7 daily of each, not 7 in total. More copies than the
policy reads like, which is fine at this size. Do not "fix" it by forcing the paths to match.

**The bucket has versioning OFF, deliberately.** `forget --prune` deletes and rewrites pack files;
with versioning on, every deletion is retained as a noncurrent version, so pruning frees nothing
while restic reports the repository shrinking - a silent, billable divergence. Object lock is off
for the same reason: it makes prune fail outright. The append-only key is what closes the gap those
would have addressed, without breaking prune.

**Four things the backup does that a plain `rsync` does not**, each of which otherwise produces a
backup that looks complete and is not:

- **Caddy's certificates are asserted present, never assumed.** Under Docker its `/data` was
  root-owned inside the container and rsync silently skipped it. Rootless Podman maps container root
  to `core`, so it copies normally now - but the script still **fails** if it captures no
  certificates. It is 192 KB holding every TLS private key and the ACME account key, and it is
  exactly the kind of thing a permission change removes without anyone noticing.
- **Live SQLite databases are snapshotted through SQLite's backup API**, not copied. The apps run
  with WAL, so a file copy can be missing commits that live in the `-wal`.
  `bin/snapshot-databases.sh` finds them by magic bytes rather than extension - Tdarr and Jellyfin
  both use `.db` for things that are not SQLite.
- **`-wal`/`-shm` are excluded.** Restoring a stale `-wal` next to a newer `.db` is worse than
  having neither.
- **Lock files are excluded.** The backup runs with the stack live, so it captures live locks.
  qBittorrent's Qt lockfile records a pid, hostname and machine id; restored where the hostname
  differs, Qt assumes the lock is held and qBittorrent exits one second after starting, logging
  only `termination initiated`.

## A backup is not proven until it has been restored

`bin/verify-restore.sh` restores the latest snapshot to a scratch directory and asserts what came
out. Before 2026-08-14 this had never been done on the current config tree: the only restore ever
performed was during the migration, from a backup that predated Caddy, Pocket ID and Tinyauth, so
every claim about restoring TLS and sign-on was inference.

**All three copies have now been restored end to end**, on 2026-08-14, each passing the same
assertions: 23 databases through `PRAGMA integrity_check`, 11 certificates, the ACME account, and
every named database including Pocket ID's passkey store.

| Copy | Proven by |
|---|---|
| server local | `TMPDIR=/var/tmp bin/verify-restore.sh` on the server, against `/var/backups/home-server` |
| workstation pull | `bin/verify-restore.sh` |
| **off-site** | `bin/verify-restore.sh --repo offsite` - 5.6 GB pulled back from Scaleway |

The off-site one is the test that mattered, because it is the only copy that survives `nvme0n1`, and
it restored the snapshot **the server itself wrote** rather than a copy of the workstation's chain.

**Restoring 5.5 GB needs somewhere to put it, and `/tmp` is not it.** On the workstation `/tmp` is
tmpfs with 7.6 GB free out of 15 GB of RAM, so the obvious default would unpack the tree into memory
and run out partway through, after downloading several gigabytes. `verify-restore.sh` defaults to
disk-backed storage and refuses up front if the scratch filesystem is `tmpfs` or too small, naming
the `TMPDIR` override in the error.

**It checks the exclusions BEFORE it opens any database, and that ordering is load-bearing.**
Opening a WAL-mode SQLite file creates a `-shm` and a `-wal` beside it *even read-only*, so checking
afterwards finds files the verification itself created and blames the backup. It did exactly that on
its first run: 40 strays, all 0 bytes, all stamped with the time of the check rather than of the
snapshot. The databases are now opened with `immutable=1`, which promises SQLite the file cannot
change so it skips WAL recovery entirely - true of a restored snapshot, and it touches nothing.

**Loss of the workstation is now survivable, which it previously was not.** The local restic
repository, both age private keys and every restic password used to live only there. The server's
copies are in sops; the rest is why **the age keys and both restic passwords must be in the password
manager** - off-site backups you cannot decrypt are not backups.

## Logs and status

**`/var/lib/home-server/status.json` is the machine-readable interface**, rewritten hourly by
`bin/verify-host.sh` alongside the MOTD. It exists because the dashboard that is coming needs
something to read, and scraping ANSI-coloured text or re-implementing 50 checks are both worse.

**Every finding is keyed by a STABLE ID, and the prose is not stable.** A consumer keys on
`cdi.driver_match`; the sentence after it gets reworded whenever it turns out to be wrong, and that
must cost nothing. Ids are `<section>.<property>`, named for what is being measured rather than for
the verdict - `cdi.driver_match`, never `cdi.driver_ok`.

```bash
bin/verify-host.sh --json | jq '.summary, .facts'
jq -r '.checks[] | select(.status != "pass") | "\(.status)  \(.id)  \(.message)"' \
  /var/lib/home-server/status.json
```

Four properties a consumer can rely on:

- **`summary.status`** is `pass|warn|fail` - one field to colour on, so nobody re-derives precedence.
- **A section that did not run is ABSENT, not zero-filled**, and `mode.routes` says so a second
  time. "The route battery was not walked" must not read as "every route passed".
- **`facts` keys are flat snake_case and always present**, `null` when not measured - so a key never
  appears and disappears and force a reader to guess which case it is in. Check ids are dotted,
  fact keys are not; the two namespaces cannot be confused.
- **`generated_at` is authoritative.** This is also the script's own durable record: it was the only
  automated job here that wrote no marker of its last success, and a MOTD lives on tmpfs. A failing
  run carries the previous `verify_last_ok_at` forward, so "failing since Tuesday" and "has never
  once passed" do not look alike.

**`--greenboot` emits no JSON, and combining the two flags is an error.** That mode runs as root
before the user session exists and its exit code decides whether the OS rolls back, so it gets no
new failure modes and its stdout stays what it is - the only legible account of why a machine
reverted.

**Every check in the `Logs` section is WARN or PASS, never FAIL.** `bin/reboot-host.sh` refuses to
reboot a host this battery calls unhealthy, so a FAIL there would block reboots over a log
directory - and none of those findings is fixed by a reboot. Same mistake the `/boot` pin logic
already documents. Adding a FAIL to that section needs its own written argument.

### The policy, and why it is asserted rather than trusted

Until 2026-08-15 there was **no journald configuration in this repository at all** - the host ran on
uCore's `Storage=persistent` and inherited defaults, so retention was "10% of `/var`, capped at
4 GB, about three weeks", true and undeclared. It is now `host/journald/10-home-server.conf`:
**90 days, with a 16 GB cap as the runaway backstop rather than the binding constraint.**

| Measured before the change, 2026-08-14 | |
|---|---|
| journal on disk | 438 MB, all since the migration - **~193 MB/day** |
| entries/day | 128,423 |
| podman `health_status` | 34,738/day at 3.8 KB - **47.3% of all journal bytes** |

**The two files deploy differently, and that is not an oversight.** journald is parsed by PID 1,
which SELinux will not let read `var_t`, so its drop-in is **duplicated** into `host/butane/ucore.bu`
rather than symlinked - the trap `host/greenboot/README.md` documents, where `systemctl cat` prints
the file happily, no AVC is logged, and none of it applies. podman reads its config as `core`, an
ordinary user process, so `host/containers/containers.conf` **is** a symlink, like the quadlets.
**Ignition runs once at first boot**, so `ucore.bu` does not configure the running machine; both
still need applying by hand there.

**`logs.healthcheck_events` is a probe rather than a file read, and that is the point.** `podman
info` does not expose `healthcheck_events`, so the only way to know the setting is in force is to
**count the events it was supposed to have stopped** - the same argument as the nightly off-site
delete-probe. Sixteen containers on a 60s interval would put ~960 in a one-hour window; zero is the
proof. **Zero from zero containers proves nothing**, so that case is a note rather than a pass.

**What turning the events off costs**, because it is a trade rather than a free win: there is no
longer a journal record of the moment a container flips unhealthy. Three things already cover it -
`Notify=healthy` is unaffected (sd_notify, not the event log, so auto-update's rollback still
fires), `podman inspect` keeps the last 5 check results with their output, and `verify-host.sh`
checks `--filter health=unhealthy` hourly. Every **lifecycle** event survives.

**App-written log files need no new machinery.** They are 11 MB across 69 files, the \*arr apps and
unpackerr rotate themselves, and `bin/backup-server.sh` already excludes `*.log`, `*/logs/`,
`jellyfin/log/` and `tdarr/logs/` - so they are out of the backup. `logs.config_log_size` is a
tripwire on the NVMe, not a rotation policy.

## Commands

All of these run on the server as `core`, from `/var/home-server`. **No `sudo`** - the stack is
rootless, and `systemctl --user` is a different unit space from `systemctl`.

```bash
git pull && systemctl --user daemon-reload    # the whole deploy; quadlets are symlinked in
./bin/render-env.sh                           # regenerate .env after a secrets change
systemctl --user restart <service>
systemctl --user status <service>
journalctl --user -u <service> -f
podman ps                                     # STATUS shows healthy/unhealthy
systemctl --user list-units --failed          # the fastest health check
podman ps --filter health=unhealthy           # the one that catches a live-but-broken service

systemctl --user start caddy-build            # after editing apps/caddy/Dockerfile (~75s)
podman exec caddy caddy reload --config /etc/caddy/Caddyfile   # routing change, no downtime

./bin/verify-host.sh                          # the whole battery; also writes the MOTD
./bin/verify-host.sh --routes                 # plus the public routes (slow)
./bin/verify-host.sh --json | jq .summary     # the same findings, machine-readable
jq -r '.checks[]|select(.status!="pass")|"\(.status)  \(.id)  \(.message)"' \
  /var/lib/home-server/status.json            # what the hourly run last found
./bin/verify-media.sh "/mnt/media/library/transcoded/movies/<film>/<film>.mkv"
./bin/verify-media.sh --library movies        # will these drift in a browser?
podman auto-update --dry-run                  # 17 rows with a policy, not an empty table
systemctl --user list-timers                  # verify hourly, backup + auto-update nightly

systemctl --user start home-server-backup     # back up now rather than waiting for 03:00
journalctl --user -u home-server-backup -n 50
```

**From the workstation**, because they either need credentials the server does not have or have to
outlive the machine they are talking about:

```bash
./bin/verify-restore.sh                       # does the latest snapshot actually restore?
./bin/verify-restore.sh --repo offsite --deep # the copy that survives the disk, data re-read
./bin/backup-config.sh && ./bin/backup-offsite.sh   # the third copy, and the off-site prune
./bin/reboot-host.sh --dry-run                # pre-flight for the one dangerous operation
./bin/lint-repo.sh                            # ASCII, exec bits, shellcheck, quadlet dry-run
```

**Updates are automatic, in two independent tracks.** Containers: `podman-auto-update.timer`
nightly, following tags, rolling back on a failed start. Host: `rpm-ostreed-automatic.timer`
nightly, which **stages and never reboots**. Applying it is either a deliberate human act via
`bin/reboot-host.sh`, or `home-server-reboot.timer` hourly from 05:00 to 09:00 on Sundays - which
applies a staged deployment only when greenboot is armed to undo it and refuses on anything else.
**Five attempts rather than one, because the refusal that actually fires is transient**: the
encoder gate means a Tdarr job running at 05:08 used to cost the deployment a whole week. A
deployment that
boots but breaks sshd now rolls itself back rather than being a car journey; `bin/verify-host.sh`
still tells you one is waiting, via `/run/motd.d/`.

**The reboot procedure, which is the only genuinely dangerous step, is now a script.** Run it from
the **workstation**, because the waiting cannot happen on the machine that is rebooting:

```bash
./bin/reboot-host.sh --dry-run    # pre-flight only: health, /boot, encoder idle, what is staged
./bin/reboot-host.sh              # the whole sequence, with a typed confirmation
```

It does what the hand procedure did, with the two mistakes that have actually been made built in as
code rather than as warnings to remember: it derives the **booted** deployment index rather than
assuming 0, and it unpins and runs `rpm-ostree cleanup -r` afterwards. **On a failed verification it
stops with the pin still in place**, because that pin is the rollback.

```bash
# what it does, if you would rather type it
rpm-ostree status && df -h /boot              # what is staged, and room to apply it
systemctl --user list-units --failed; podman ps --filter health=unhealthy
nvidia-smi --query-gpu=utilization.encoder --format=csv   # 0,0 - nothing mid-encode
# pin the BOOTED deployment - NOT index 0, which is the staged one when one exists
idx=$(rpm-ostree status --json | jq '[.deployments[]] | map(.booted) | index(true)')
sudo ostree admin pin "$idx"
sudo systemctl reboot                         # on a day you could reach the machine
./bin/verify-host.sh                          # then UNPIN - a pin can cost a whole /boot slot
idx=$(rpm-ostree status --json | jq '[.deployments[]] | map(.pinned) | index(true)')
sudo ostree admin pin "$idx" --unpin && sudo rpm-ostree cleanup -r
```

**A unit stuck in `activating` is usually a `Restart=always` loop, not slow progress.** Read the
journal rather than waiting - the real error scrolls past between restarts, and the restart counter
tells you how long it has been failing.

There is no `docker compose config` equivalent. The nearest linter is generating the units without
starting anything, which catches syntax errors but **not** unset variables:

```bash
/usr/libexec/podman/quadlet -dryrun -user
```

**That path, not `/usr/lib/systemd/user-generators/podman-system-generator`** - this podman ships
the generator as `podman-user-generator` and the standalone binary is the one above. The wrong path
fails with `No such file or directory`, which reads like the check is unavailable rather than
misspelled.

Changing a network's subnet or options is not a live edit: a network cannot be modified in place or
removed while containers are attached, so it takes stopping the stack, `podman network rm`, and
starting again.

The Caddyfile can be checked without deploying it, which is worth doing since a bad one takes the
whole ingress down. `acme_dns gandi` does not exist in the stock image, so validation needs the
custom build:

```bash
podman run --rm -v "$PWD/apps/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e DOMAIN=example.com -e PORT_TDARR_WEB=8265 \
  -e PORT_QBITTORRENT_WEB=8200 -e PORT_JOAL_WEB=8221 -e GANDI_BEARER_TOKEN=dummy \
  home-server/caddy:latest caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Architecture

**Everything is parameterised through `.env`.** Ports, paths, subnets, credentials and image
settings are all variables. Required ones use `${VAR:?err}` so compose fails loudly rather than
silently substituting empty strings. Follow that convention: `:?err` for required, bare `${VAR}`
for optional.

**One network per trust boundary, and the split is the security model.** Services address each
other by container name (`http://sonarr:8989`), but only where they share a network:

| Network | Members |
|---|---|
| `net-ingress` | caddy, tinyauth, pocket-id |
| `net-arr` | caddy, sonarr, radarr, prowlarr, jellyseerr, unpackerr, bazarr |
| `net-solver` | prowlarr, flaresolverr |
| `net-download` | caddy, gluetun, sonarr, radarr, prowlarr |
| `net-media` | caddy, jellyfin, jellyseerr |
| `net-transcode` | caddy, tdarr-server, tdarr-node-01 |
| `net-egress` | duckdns |

Each has its own `NET_SUBNET_*` variable. **Caddy joins every segment individually** - a shared
"proxy" network holding everything with a UI would re-flatten the topology and buy nothing. It is
deliberately absent from `net-solver`.

**Isolation is not free under Podman, and this is the single most important difference from the
Compose stack.** Docker put every bridge in `DOCKER-ISOLATION-STAGE-2` and dropped traffic between
them, which is what made "no shared network means no route" true. **Netavark does not.** Created
plain, these seven networks were fully routable to one another - measured, not assumed: a container
on `net-solver` reached Sonarr on `net-arr` by IP, and so did `net-media`, `net-egress` and
`net-transcode`. The topology looked segmented and was flat.

Every `.network` unit therefore carries `Options=isolate=true`. **Do not remove it, and do not add a
network without it.** It constrains bridges rather than membership, so Caddy still reaches each of
the five segments it joins.

Verify a forbidden edge **by IP, from a throwaway container on the source network**, never by name
resolution: a container has one address per network it joins, a name proves only one of them, and
the unit files look identical either way.

```bash
podman run --rm --network net-solver docker.io/library/busybox nc -w3 -z <sonarr-ip> 8989
```

Distinguish *refused* from *timeout* when reading the result. Connection-refused means the packet
arrived and only the port was shut - that is not a blocked edge.

`net-solver` and `net-media` carry most of the value. FlareSolverr exists to run headless Chrome
against attacker-controlled indexer pages, so it is the likeliest thing here to be compromised;
Prowlarr is now all it can see. Jellyfin is the inverse - the most exposed service, LAN and public
- yet it initiates no internal connections at all, so it reaches nothing.

**`gluetun` is the egress chokepoint.** qBittorrent and JOAL both use
`network_mode: "service:gluetun"`, meaning neither has a network stack of its own: they live inside
the VPN container's namespace. If the VPN drops they lose connectivity entirely, which is a
kill-switch by construction. **Never give a downloader its own `networks:` entry** - it would leak
traffic outside the VPN. gluetun's own `networks:` entry is what puts all three on `net-download`.

JOAL is in there because it announces to trackers, and would otherwise do so from the host's own
IP while qBittorrent used the VPN.

**Neither has a name of its own. The address is `torrent:<port>` - the pod.** Under Compose it was
`gluetun:<port>`, because `network_mode: service:gluetun` made gluetun the container attached to
`net-download`. Under Podman the pod's **infra** container holds the network and answers to the
*pod* name, so `gluetun:8200` does not resolve at all - and neither does `qbittorrent:8200`.

Everything addressing them needs that name: the Caddyfile, and the \*arr apps' download client
settings, **which live in their databases and not in this repository** - so a `git grep` does not
find them and a restore brings the old value back. Check them through the API:

```bash
curl -H "X-Api-Key: $KEY" http://sonarr:8989/api/v3/downloadclient   # host must be "torrent"
```

This is invisible until something actually downloads, because those routes sit behind sign-on and
an unauthenticated request never reaches the backend.

**Changing a network is not a live edit**, and that covers its options as much as its subnet. Podman
will not modify a network in place, will not create one whose pool overlaps an existing one, and
will not remove one with containers attached - so a partial attempt leaves the stack half-started.
It takes stopping every unit, `podman network rm`, `systemctl --user daemon-reload`, then starting
again in order. Do it from a script running server-side: it outlives a dropped SSH session, and the
half-way state is one where nothing is reachable.

**No peer port is published on the host.** With `VPN_PORT_FORWARDING=on`, incoming peers arrive
through the tunnel on the port ProtonVPN forwards, landing straight in gluetun's namespace.
That port changes on every reconnect, so `VPN_PORT_FORWARDING_UP_COMMAND` pushes it into
qBittorrent over its API each time the tunnel comes up; without that the two silently drift apart
and the client goes unconnectable. Publishing 6881 on the host would only forward to a port
nothing listens on.

`unpackerr` needs `net-arr` despite touching only the filesystem - it discovers what to extract
by polling the Sonarr and Radarr queue APIs.

**One media mount, not several.** Every service that has to move files mounts `${DOCKER_VOLUME_MEDIA}`
(`/mnt/media`) as a single `/data`, so `downloads/` and `library/` are on one filesystem and the
\*arr apps can hardlink/atomic-move instead of copying. Mounting subdirectories separately would
break that and silently double disk usage. Verified working: an imported film is `links=2` with its
seeding download, and the two paths share their bytes.

**Jellyfin is the deliberate exception** - it mounts only `library/` at `/data/media`, because it
never moves a file and has no business seeing `downloads/`. Do not "fix" it to match the others.

**The library is a pipeline, not a folder.** `library/queued/<type>` is where the \*arr apps import
to, Tdarr transcodes, and Jellyfin serves *only* `library/transcoded/<type>`. `<type>` is one of
`anime`, `documentaries`, `movies`, `series`; `review/` is the manual siding and `.recycle` is the
\*arr recycle bin, deliberately outside every Jellyfin library path. A root folder that omits the
`queued/` or `transcoded/` level exists nowhere on disk - which is how Jellyseerr came to file every
request into three paths that did not exist, so nothing requested through it could import at all.
**Check a new root folder against the disk, not against what looks plausible.**

**Tdarr's flow DOES promote the file; what was missing is telling the \*arr apps.** The old five-flow
chain transcoded in place and left everything in `queued/`, which is where the "correctly downloaded,
correctly imported, correctly transcoded, invisible in Jellyfin" failure came from. `avsOnePass1`
ends in a `moveToDirectory` node reading `{{{args.userVariables.library.output_dir_done}}}`, and
**every library defines that** - `/media/library/transcoded/<type>`. So the file moves itself.

**Those variables live in the `variablesjsondb` table, keyed `library:<id>`, not on the library
document.** `LibrarySettingsJSONDB` reports `userVariables: null` for all four libraries, which makes
the flow look broken when it is not. Read them with:

```bash
podman exec tdarr-server curl -sf -X POST -H 'Content-Type: application/json' \
  -d '{"data":{"collection":"VariablesJSONDB","mode":"getAll"}}' \
  http://localhost:8266/api/v2/cruddb | jq -r 'sort_by(.type,.key)[]|"\(.type) \(.key)=\(.value)"'
```

`bin/promote-transcoded.py` therefore reconciles rather than promotes: it tells Radarr and Sonarr
where Tdarr already put the file. Run every 10 minutes by `home-server-promote.timer`.

**It covers all four types, and each needs BOTH root folders to exist.** Radarr owns
`movies` + `documentaries`, Sonarr owns `series` + `anime`. It used to handle one type per
application, so a transcoded documentary moved to `transcoded/documentaries` and Radarr was never
told - the same failure, in a folder nobody watches. The script now refuses per type, loudly, when
the target is not a configured root folder, because the *arr editor call silently rejects a path the
application does not know.

It runs **on the host, not in a container**, and that is the design rather than an accident:
`net-transcode` is `isolate=true` and holds only Caddy and the two Tdarr containers, so Tdarr
cannot reach Radarr, Sonarr or Jellyfin and should not be able to. `podman exec` works regardless of
network topology, so the reconciler grants no container any reachability it did not have.

**It never touches a media file.** It reads the filesystem to see where each film actually is, then
calls the \*arr editor endpoints with `moveFiles: false` plus a rescan - the flow has *already* moved
the file, so the applications only need to be told. Anything that moves a file behind an \*arr's back
orphans it, which is what left *Flow* and *The Hobbit* in `transcoded/` while Radarr reported
`hasFile=false`. **Do not add a step that moves media directly.**

**It decides "has this moved?" by looking for a VIDEO FILE, never for the directory**, and that
distinction is the difference between working and silently doing nothing. It originally tested
`os.path.isdir()` on the queued folder. Tdarr does delete the film, with
`deleteParentFolderIfEmpty:true` - but the folder is not empty, because Radarr and Sonarr write
`fanart.jpg`, `poster.jpg` and a `.nfo` beside it. So the directory always survived, `gone` was never
true, and **the script never promoted a single file in its entire existence** while cheerfully
reporting "12 still in queued/, 0 moved by Tdarr". *Flow* and *The Hobbit* sat unmapped for nine
months as a result. If a reconciler here looks like it is working, check that it has actually done
something.

**It now names a STALL rather than reporting it as patience.** `gone=False, arrived=False` used to
be counted as "waiting on Tdarr", which is also what a live transcode looks like - so a file the
flow had abandoned was indistinguishable from one still being worked on, for ever. The script now
also reads Tdarr's `FileJSONDB` and prints `STUCK:` when a file still sitting in `queued/` already
carries a finished verdict (`Not required` or `Transcode success`). The Tdarr call is best-effort:
if it fails the set comes back empty and the script behaves exactly as it did before, because a
diagnostic must never be able to break the reconciliation it annotates.

## The flow trap: an unwired output silently eats the file

**A classic plugin's "nothing to do" answer is a SEPARATE flow output, and it must be wired.**
`runClassicTranscodePlugin` **2.0.0** returns `outputNumber: 1` when it transcoded and
**`outputNumber: 2` when the file was already compliant**. `avsOnePass1` wired only output 1, so
every source that was already HEVC under the 8 Mbps threshold hit a dead end: Tdarr recorded
`Not required`, the flow ended before `aMoveDone`, and the file stayed in `queued/` where Jellyfin
does not look - while Radarr, Tdarr and Jellyfin were each individually correct and
`promote-transcoded.py` printed "1 waiting on Tdarr" every ten minutes. *The Hobbit: The Battle of
the Five Armies* and *The Punisher: One Last Kill* both went this way inside two days.

Version 1.0.0 returned `outputNumber: 1` on that branch, so the dangling edge was harmless until the
stack moved 2.55.01 -> 2.71.01. **A plugin version bump can make an unwired output load-bearing**,
and nothing warns you: the job report says the run finished, and the file simply does not move.

Output 2 now goes to **`aMoveKeep`, a second `moveToDirectory` node that nothing follows**, skipping
`aStats`, `aSize` and `aHealth` deliberately - there is no new output to recompute statistics for,
comparing a file's size against itself is meaningless, and `aHealth` is a full-file decode that on
this branch would run against the source **on the spindle**, since nothing was ever staged to the
NVMe cache. That is the operation that took the whole host down once already.

**Wiring output 2 into the existing `aMoveDone` does NOT work, and the reason is worth keeping.**
`aMoveDone` is followed by `aDelete`, configured `fileToDelete: originalFile`. On the transcoded
branch the original and the working file are different, so that is correct. On the compliant branch
**they are the same file**, so the move leaves nothing behind and `aDelete` fails with
`ENOENT ... unlink`, which Tdarr treats as `Flow has failed` and records as `transcodeError`. No data
is lost - a rename within one filesystem preserves the inode and its hardlink to `downloads/`,
verified with `stat` - but every compliant file would be filed as an error for ever. Tried on *The
Hobbit*, corrected, then confirmed clean on *The Punisher: One Last Kill*. **A flow can move the file
correctly and still record an error on a later node**, so check the verdict as well as the file.

## Tdarr's file tables are the QUEUE, not a history

**"Transcode success" and "Not required" are views over the current library file table**
(`filejsondb`), which this pipeline drains to zero on purpose: every library watches
`/media/library/queued/<type>` only, and the flow moves output to `transcoded/<type>`, outside every
watched folder - so the folder watcher reaps each file from the table as it is promoted.
`scanOnStart=True` makes the sweep run at every container start, which is why it looks like a reboot
wiped something.

**Nothing is lost, and there is nothing to fix.** `/app/server` is a host bind mount, and Tdarr 2.86
has migrated off NeDB to one SQLite file at `Tdarr/DB2/SQL/database.db`. The durable history is
`jobsjsondb` - 2,659 rows as of 2026-08-14, surfaced in the UI on the **Jobs tab**. That is where to
look; a short Transcode-success table means the queue is empty, which is the goal.

**The 27% lifetime error rate is history, not a live fault.** 689 of 710 `Transcode error` rows are
from March 2025 - the destructive community flow documented above - and the five in August 2026
predate the repointing to `avsOnePass1`. Check the month distribution before investigating.

## All four Tdarr libraries, and what differs between them

Movies, Documentaries, Series and Anime all run `avsOnePass1` with `processLibrary=true` and
`processHealthChecks=false` - the flow health-checks each output while it is still on the NVMe
cache, so a library-wide check would only add full-file decodes off the spindle, which is what
wedged the host once already.

Until 2026-08-14 the other three pointed at **`htpX8Ypt1`, the destructive community flow**, with
processing off. Enabling them without repointing would have been actively harmful, not merely
useless.

**The one thing that genuinely differs per library is the audio whitelist**, and it differs because
of anime. The transcode node reads
`audioLanguages = {{{args.userVariables.library.audio_languages}}}`:

| Library | `audio_languages` |
|---|---|
| Movies, Documentaries, Series | `eng,fra,fre,und` |
| Anime | `jpn,chi,zho,kor,eng,fra,fre,und` |

**Anime VO is not always Japanese** - donghua is Chinese, aeni Korean - so the list covers all three
plus English and French, which are wanted when a release carries them *alongside* the VO. Without
this the default whitelist would have dropped a Japanese track on any release that also had English,
since the plugin's "keep everything" safety net only fires when **nothing** matches. That is the
exact bug class the plugin exists to prevent, and it would have been silent.

Subtitles stay at the plugin default `eng,fra,fre` for every library.

**Radarr and Sonarr both hold two types**, so each needs four root folders in total; `transcoded/`
counterparts for documentaries and anime were missing entirely and were added the same day. Jellyfin
already had a library per type, each reading `transcoded/<type>`.

**Sonarr's anime scoring is a preference, not a rule.** `Lang: Dual Audio` scores 100 in the one
quality profile, so a dual-audio release wins between otherwise-equal candidates - but
`minFormatScore` and `cutoffFormatScore` are both **0**, so a subbed VO-only release is perfectly
acceptable and Sonarr will not hunt for an upgrade purely to get a dub. Note the profile's other
formats (the TRaSH `Anime_10_*` set) score up to **4000**, so any cutoff low enough to be reachable
is satisfied by the first release that arrives: expressing "keep looking until dual audio" would
mean rescoring the whole profile, not moving the cutoff. The enabled `Anime` release profile ignores
`\bdub(bed)?\b`, which is what stops a dub-only release replacing the VO.

## The transcode policy

**One ffmpeg pass, defined by one tracked plugin.** `apps/tdarr/plugins/Tdarr_Plugin_avs1_MediaStackStreamPolicy.js`
is a *classic* Tdarr plugin - deliberately, not a flow plugin: a flow plugin must live at
`Plugins/Local/FlowPlugins/<cat>/<name>/1.0.0/index.js` and the community ones reach `FlowHelpers`
through relative `require`s that **do not resolve from `Local/`**. A classic plugin is one file in
`Plugins/Local/`, its single `require('../methods/lib')` is correct there, and it returns the raw
ffmpeg argument string. The flow `avsOnePass1` is then only 7 nodes around it.

It is **tracked in git** and copied into the gitignored `config/` tree by an `ExecStartPre=` on
`tdarr-server.container`. Editing the copy on the server is pointless; it is overwritten every start.

Things in it that are not obvious and cost time to find:

- **The keyframe interval is PINNED at just over 6 seconds, and it is not a tuning knob.**
  `keyframeSeconds` (default 6) becomes `-g N -keyint_min N -no-scenecut 1`, with `N` derived from
  the source frame rate - 145 at 23.976 fps, 151 at 25, 181 at 29.97. Left to itself NVENC uses a
  250-frame cap plus adaptive I-frames at scene cuts, which produces gaps anywhere from 0.2 s to
  10.4 s and breaks browser playback outright - see the drift entry under Known state.
  **`-no-scenecut 1` is the load-bearing half**: without it NVENC keeps inserting keyframes at cuts,
  the gaps fall back below 6 s and the whole failure returns. It works because `-rc-lookahead 32` is
  already set; the option is ignored without lookahead. The frame rate is parsed from
  `r_frame_rate`, which ffprobe reports as the **rational string** `"24000/1001"` - `parseFloat` on
  that yields 24000 and would put the interval out by a factor of a thousand.

  **It costs nothing; it SAVES about 5%.** Measured on the same 90 s clip at CQ 26, preset p6:
  19,989,619 bytes with the old arguments against **18,997,172 with the new ones**, and the keyframe
  gaps went from 1.6-6.0 s to a flat 6.047-6.048 s. An I-frame is far more expensive than the P and
  B frames it displaces, so dropping the adaptive ones more than pays for having no keyframe exactly
  on a cut. The expectation going in was a small loss; measure this sort of thing rather than
  reasoning about it.
- **10-bit is done with `-vf scale_cuda=format=p010le`, NOT `-pix_fmt p010le`.** With
  `-hwaccel_output_format cuda` the frames never leave GPU memory, so a pixel-format conversion has
  nowhere to happen and ffmpeg fails with *"Impossible to convert between the formats supported by
  the filter 'Parsed_null_0' and the filter 'auto_scale_0'"*. Do not "simplify" it back.
- **Opus bitrates are TOTAL, not per channel** - 128k stereo, 256k 5.1, 450k 7.1. The old flow
  multiplied by channel count and produced 1536k and 2048k Opus, which is why it made files *bigger*.
- **Opus only for codecs that do not direct-play** (truehd/dts/flac/pcm/mlp). AAC, AC3, E-AC3, MP3
  and Opus are copied: lossy->lossy is generation loss for nothing. Plain DTS *is* converted despite
  being lossy - it is badly supported and runs 768-1536 kb/s.
- **The AC3 companion is decided per LANGUAGE, not per file.** These releases carry French AC3 next
  to an English DTS-HD VO, so a per-file "does an AC3 exist?" test wrongly concludes yes and leaves
  the VO Opus-only - precisely the direct-play case the companion exists for.
- **Channel count is never a selection criterion.** The old flow filtered audio by "keep the highest
  channel count" *before* looking at language, which is what deleted VO tracks.
- Inside the container **only one GPU is visible, so the healthy card is ordinal 0**. `-gpu 1` and
  `-hwaccel_device 1` fail there with `CUDA_ERROR_INVALID_DEVICE`.

**CQ 26, calibrated not guessed.** Against a 20 Mbps VC-1 remux (60 s, preset p6, SSIM vs source):

| CQ | 20 | 22 | 24 | 26 | 28 |
|---|---|---|---|---|---|
| kbps | 9631 | 8618 | 6354 | 4541 | 3179 |
| SSIM | .98817 | .98771 | .98584 | .98379 | .98164 |

SSIM moves **0.0065 across a 3x bitrate range** - there is no cliff to find, so this is a storage
decision, not a technical one. `v_cq=18` was the old value and is near-lossless.

**A subtitle-inclusive benchmark cannot use `-t`.** Copying sparse PGS streams makes ffmpeg read the
*whole* file to flush them, so a 60-second test of a 22 GB film took 131 s instead of 9 s. Production
encodes the whole file anyway and pays nothing. Measure video-only, or measure the real thing.

## The Radarr [VO] profile encodes one rule: VO now, French when it appears

Profile 9 `[VO]` is the only Radarr profile that scores custom formats, and every film is on it.
The scoring says: **a VO-only release is acceptable, but keep looking until one carries French too,
then stop.**

| Setting | Value | Why |
|---|---|---|
| `minFormatScore` | 30 | A VO-only release scores ~50, so it is grabbable. |
| `Lang: Original + French` | **500** | Dominates every other format, so a French-carrying release always outranks a VO-only one. |
| `cutoffFormatScore` | **500** | Satisfied *only* by French. Reaching it is what makes Radarr stop searching. |
| `Rejected: 3D` | **-10000** | `3D`/`SBS`/`OU` in the release title. |

It was `cutoffFormatScore: 300`, which required `Global: Best` - AV1 **and** surround **and**
Original **and** French. That is effectively unobtainable, so nothing ever satisfied the cutoff and
every monitored film would have been searched for upgrades for ever.

**Radarr scores an existing FILE from its stored `sceneName`, not the renamed filename.** That is
what makes this work: the eight Harry Potter films are renamed to `Title (Year).mkv` with no
language markers, yet they score **820** because Radarr still holds
`...MULTI.1080p.BluRay.REMUX...`. They are at cutoff and inert. The Hobbit files score 50, and
*Battle of the Five Armies* scores **-9150** because the 3D penalty applies to existing files too -
which is exactly what let a 7.7 GB 2D release replace a 38.3 GB 3D one that Radarr had recorded as
`Bluray-2160p` (it is 3840x1080 side-by-side, so it looks like 4K by width).

**Check `/api/v3/moviefile`, not `/api/v3/movie`.** The movie list endpoint returns the nested
`movieFile` *without* `customFormatScore`, so every film reads `None` and looks below cutoff.

## Downloads are hardlinked, so the "source" usually still exists

`copyUsingHardlinks: true` means `library/queued/...` and `downloads/...` are the **same inode**
(`stat` shows `links=2`). Two consequences worth knowing before reaching for a re-download:

- The 130 GB in `queued/` costs nothing on top of `downloads/`, and Tdarr deleting the queued path
  leaves the torrent seeding untouched.
- **A film the pipeline damaged can usually be restored locally.** Five films lost their French dub
  to the old flow and had their queued copies deleted - but the original `MULTI` remuxes were still
  seeding, so `os.link()` put them back for 0 bytes and no bandwidth. **Look in `downloads/` before
  re-downloading anything.**

## Ingress and access control

**`caddy` is the single TLS terminator**, built from `apps/caddy/Dockerfile` because the official
image ships no DNS provider modules. All routing is `apps/caddy/Caddyfile` - one site block per
hostname, mounted as a directory so a `git pull` replacing the file does not leave the container
holding a stale inode.

**Certificates are issued per site block, on demand, over DNS-01 against Gandi** using a Personal
Access Token (`GANDI_BEARER_TOKEN`). Consequences worth knowing:

- There is **no certificate list to maintain**. Adding a service is a CNAME plus a Caddyfile block.
- **A hostname with no block gets no certificate and fails the TLS handshake**, so unlisted names
  are closed by construction rather than by remembering to remove them.
- `*.avanserv.com` belongs to a different server and is not available here, so names stay flat and
  explicit and each new service needs its own CNAME.
- The credential is a **PAT, not the legacy `dns_gandi_api_key`** certbot used. That type is
  deprecated and `caddy-dns/gandi` will not authenticate with it.

**Access control is passkey single sign-on.** Pocket ID is the OIDC provider; Tinyauth bridges
Caddy's `forward_auth` to it, because Pocket ID has no forward-auth endpoint of its own:

```
browser --> caddy --forward_auth--> tinyauth --OIDC--> pocket-id (passkey)
```

Two things about this that are easy to get wrong, both learned the hard way:

- **Tinyauth returns 401 with the login URL in `X-Tinyauth-Location`, not in `Location`.** Caddy
  turns that into a redirect via `handle_response`. Without it the integration still *refuses*
  requests correctly, so it looks like it works, while showing a bare 401 in the browser. The
  snippet in Tinyauth's own Caddy documentation stops short of this.
- **`POCKETID_APP_URL` must match the browser's origin exactly, port included.** WebAuthn strips
  the port when deriving the relying-party ID, but the server validates the full origin string
  separately. A mismatch fails registration at `/api/webauthn/register/finish` with an unhelpful
  "couldn't process the response from your passkey".

`watch` and `request` are the only routes not behind sign-on: both authenticate their own users,
and their clients have no browser in which to complete a passkey prompt.

**Almost nothing publishes a host port.** Caddy reaches each service by name over its network, so
admin ports were a second path in that sign-on did not cover. **Two publishes remain**, each for
something that must be spoken to without the proxy: Caddy's 80/443, and Jellyfin for LAN clients.
Gluetun's used to be a third and is gone with its proxies. **Do not add a `ports:` entry for a
service Caddy can reach by name.**

## `config/` is ignored wholesale, and `apps/` is why it can be

Everything under `config/` is **runtime state on the server** - application databases, Jellyfin
metadata, Caddy's certificates and ACME account, Pocket ID's passkey records. It is not in git.
Treat it as precious: it is the one thing here that cannot be rebuilt from this repository, which
is what the whole Backups section above exists for.

**`.gitignore` is a single `config/` rule, and adding an exception to it is the wrong move.** It
used to carry a four-rule un-ignore chain (`config/*`, `!config/sonarr/`, `config/sonarr/*`,
`!config/sonarr/scripts/`) because git will not descend into an ignored directory to find an
exception inside it. All of that plumbing existed to track one 9-line script.

**A file that has to reach a container's config tree goes in `apps/<service>/` and is copied in by
an `ExecStartPre=` on that service's quadlet.** That is the same contract Tdarr's plugin always
had, now used for all of them:

| Tracked at | Lands at | How |
|---|---|---|
| `apps/caddy/` | `/etc/caddy` | bind-mounted read-only, as a directory |
| `apps/tdarr/plugins/` | `config/tdarr/server/Tdarr/Plugins/Local/` | `cp -a` |
| `apps/sonarr/scripts/` | `config/sonarr/scripts/` | `cp -a` |
| `apps/jellyfin/custom.css` | `config/jellyfin/branding.xml` | `bin/render-jellyfin-branding.py` |
| `apps/jellyfin/encoding.conf` | `config/jellyfin/encoding.xml` | `bin/render-jellyfin-encoding.py` |
| `apps/tdarr/flows/` | nowhere - **a record, not a deployment** | by hand; see that directory's README |

**Two things are tracked that nothing deploys, and the distinction matters.** `apps/tdarr/flows/`
holds an export of `avsOnePass1`; Tdarr has no import-from-disk mechanism, so the flow that actually
runs lives in its SQLite database and is edited in Tdarr's own flow editor. It is tracked so a flow
is reviewable and diffable at all - it decides what happens to every file in the library and was
previously recoverable from nothing but a backup of gitignored state. **Re-export it after any
edit**, or the copy in git silently becomes fiction.

**Jellyfin's `encoding.xml` came under the contract on 2026-08-15, and only in part.**
`apps/jellyfin/encoding.conf` names the elements that are decisions rather than defaults - the
keyframe-extraction extension list, throttling, the hardware-decode codec list - and
`bin/render-jellyfin-encoding.py` writes **only those**, never creating the document. That
restriction is the design, not laziness: `encoding.xml` has ~50 elements (tonemapping, VAAPI
device, CRF targets, deinterlacing) that are genuinely Jellyfin's to own, and authoring it from a
handful of tracked keys would reset every one of them by omission. **A list element must be declared
`Element[] = a,b,c`**, because an emptied list is written `<Foo />` and cannot be told from a scalar
by inspection - which is precisely the state the renderer exists to repair.

**`system.xml` and `network.xml` are still outside it**, and they hold real decisions - whether
trickplay uses the GPU, which proxies are trusted - so a `git grep` does not find them and a restore
brings back whatever was there. Treat them the way the Sonarr download-client settings are treated:
check them through the API rather than assuming.

**Git is authoritative, so editing the copy on the server is pointless** - it is overwritten on the
next start. Two consequences that are easy to be surprised by:

- **A Custom CSS edit made in Jellyfin's own UI reverts.** It survives until the next restart, and
  `podman-auto-update` restarts Jellyfin nightly, so it will look like it worked and quietly undo
  itself overnight. Edit `apps/jellyfin/custom.css`.
- **That CSS is VENDORED, and two of its stylesheets were deleted on purpose.** It used to be 16
  `@import` URLs into `CTalvio/Ultrachromic` at HEAD - an unpinned dependency on someone else's
  repository, on a page behind sign-on, plus 16 render-blocking fetches before first paint. It is
  inlined now (37 KB, ASCII, one remaining `@import` for a Google Font, which **must stay on the
  first line** - CSS ignores an `@import` that follows any rule, so moving it silently drops the
  font). `effects/glassy.css` and `effects/pan-animation.css` were **not** inlined: the first put
  `will-change: backdrop-filter` on 11 selectors including `.indicator` and `.cardOverlayButtonIcon`,
  which are on *every card*, so a 100-card page became 100+ composited layers each re-sampling what
  was behind it; the second ran an infinite `backgroundScroll` animation on the full-viewport
  backdrop, so it was never static. Together they re-blurred a moving full-screen image every frame
  and re-sampled it through a hundred layers, which is what made the UI "barely usable" while every
  other app was fine. **Do not add them back.** One narrow `backdrop-filter` survives on the three
  `.itemProgressBar` selectors; it is the next thing to remove if scrolling still stutters.
- **Sonarr's script path is recorded in `sonarr.db`, not here.** The "Clean Anime Extra Files"
  Custom Script connection stores `/config/scripts/anime-extra-files.sh`. Where the file lives in
  git is free; where it lands in the container is not, and a mismatch fails silently because that
  connection only fires on import.

## Editing this repository

There is still no build, no lint in the compiler sense and no test suite. What exists is
`bin/lint-repo.sh`, which asserts the four conventions nothing else enforces: every tracked text
file is ASCII, every script in `bin/` is executable, the shell passes shellcheck, and the quadlets
generate.

**The shellcheck leg SKIPS rather than FAILS when shellcheck is absent, and it had therefore never
run.** It was installed on neither machine until 2026-08-14, so the linter reported `all checks
passed` across 2,224 lines of shell it had not looked at - the exact shape of the problem this
repository keeps rediscovering, where a check that does nothing is indistinguishable from one that
works. The skip is still correct, because `/usr` is read-only on the server and the script has to
stay runnable there; the fix is that `bin/README.md` now names shellcheck as a workstation
prerequisite and says how to install it. The first real run found 18 issues, all of them minor.

**Prose and output here are ASCII, and that is checked rather than hoped for.** 402 non-ASCII
characters had accumulated by 2026-08-14 - em dashes, box drawing, arrows, a vulgar fraction. They
arrive by copy-paste, they are invisible in review, and in the shell scripts they end up inside
`printf` format strings that a terminal may not render. Use `-` for a dash, `->` for an arrow,
`>=` for a comparison, `x` for a multiplication sign.

**`.vscode/` is tracked**, and it exists because all 26 quadlets and 6 plain units otherwise open as
unhighlighted text. `hangxingliu.vscode-systemd-support` is the one that matters - its `systemd-conf`
language claims `.container`, `.volume`, `.pod`, `.build`, `.network`, `.service` and `.timer`, which
is every unit type here. Butane and Ignition have no extension in Open VSX at all, so `*.bu` is
associated with YAML and `*.ign` with JSON instead.

**No SOPS extension, deliberately.** The transparent-decrypt ones add a path by which a plaintext
secret can be written to disk in a public repository. `sops secrets/env.sops.env` opens it in
`$EDITOR` and re-encrypts on save without plaintext ever touching the disk.

## Known state

Conclusions from auditing the running host. Do not rediscover these:

- **Two things bit during the 2026-08-15 rename, and both would bite again on any move of the
  checkout.** The one-shot script that carried them has been deleted, so they live here:
  - **A symlink from `/etc/greenboot/check/required.d/` into the checkout dangles the instant the
    checkout moves.** A dangling entry there cannot be exec'd, so the next boot is RED and greenboot
    rolls back a deployment that was never bad - and the reboot is inside the greenboot binary, so
    no unit file hints at it. An *empty* `required.d` is green by default; a broken symlink in it is
    not. Remove it before moving anything and restore it after.
  - **Renaming a unit out from under a running timer leaves the OLD name in systemd's runtime state
    as `not-found`/`failed`** - phantoms that nothing on disk explains, that `daemon-reload` does not
    clear, and that `verify-host.sh` correctly counts as failed units for ever. Only
    `systemctl --user reset-failed` clears them, and only once the new names are linked.
- **The project was `media-stack` until 2026-08-15.** The checkout moved `/var/media-stack` ->
  `/var/home-server`, five timers and five services were renamed, `/var/lib/`, `/var/backups/` and
  `~/.cache/` followed, and `MEDIA_STACK_*` became `HOME_SERVER_*`. **Three things deliberately did
  not follow, so `git grep media-stack` still finds them and they are not misses:**
  - **The Tdarr plugin**, `Tdarr_Plugin_avs1_MediaStackStreamPolicy.js`. Its filename *is* its `id`,
    and `apps/tdarr/flows/avsOnePass1.json` references it as `Local:Tdarr_Plugin_avs1_...` - but the
    flow that actually runs lives in Tdarr's SQLite database, not in git. Worse,
    `tdarr-server.container` copies plugins with `cp -a`, not `rsync --delete`, so a rename would
    leave *both* files in `Plugins/Local/` and transcodes would keep working off the stale one until
    a config restore, then fail. The name still describes what it is: a media stream policy.
  - **The four Stage 0/1 paths in `host/RUNBOOK.md`**, which record the Fedora 37 host destroyed on
    2026-08-12 - they sit beside `/home/avanserv`, `/var/lib/docker` and `docker compose`.
  - **Git history.** Use `git grep` on the working tree as the gate, never `grep -rn .`, which
    descends into `.git/`.

  The restic snapshot identity (`--tag`/`--host`) *did* follow, but only via `restic tag --add`
  and `restic rewrite --new-host`, which rewrite the existing chain in place. **Do not simply edit
  those strings**: `forget` groups by host *and paths*, so a plain edit orphans every existing
  snapshot from the retention policy. `paths` is the one field `rewrite` cannot change, so the
  workstation's chain - staged at `~/.cache/<name>/staging` - forks regardless, exactly as the
  two-chain note under Backups describes. The old group is retired once, by hand, after the new
  one has been restored successfully.
- **`firewalld` now governs published ports, which is the reverse of the Docker host.** Under
  Docker a published port stayed reachable whatever the zone allowed, because Docker's DNAT ran
  ahead of firewalld's filtering. Rootless Podman publishes through a userspace `rootlessport`
  process that binds like any other daemon, so firewalld's INPUT rules apply normally - and the
  `FedoraServer` zone ships allowing only `ssh`, `cockpit` and `dhcpv6-client`. **Ports are now
  closed by default rather than open by default.** A new published port needs a matching
  `firewall-cmd` rule in `firewall-stack-ports.service`, or it is unreachable while the container
  looks perfectly healthy. The symptom is `No route to host` - firewalld rejects rather than drops
  - on a port whose container is logging that it is serving.
- **SELinux blocks `/dev/net/tun` until `container_use_devices` is on.** The udev rule and
  `AddDevice=` are both necessary and neither is sufficient. It presents as gluetun's
  `ERROR checking TUN device: TUN device is not available`, with **no AVC logged**, while opening
  the same node as `core` on the host succeeds - and it takes qBittorrent and JOAL down too. Note
  `container_use_dri_devices` is already on in uCore, so the GPUs work while the tunnel does not.
- **Podman does not create missing bind-mount source directories; Docker did.** A fresh host has
  none of the scratch or log paths that no backup restores. With `Restart=always` this is a silent
  5-second retry loop rather than a visible failure - the Tdarr units reached restart 126. Audit
  with: expand every `Volume=` in `stacks/` against `.env` and test each host path.
- **Podman will not guess a registry.** An unqualified `FROM caddy:2` fails under systemd with
  `short-name resolution enforced but cannot prompt without a TTY`. Every image reference must be
  fully qualified; all of them are, and are digest-pinned.
- **Every quadlet that interpolates a variable needs its own `EnvironmentFile=`**, `.network` units
  included. Unlike Compose's `${VAR:?err}`, systemd expands an unset variable to an empty string
  and logs it at info level, so the visible error is podman's - `Error: invalid CIDR address:` -
  three units away from the cause.
- **`/mnt` is a symlink to `/var/mnt` on CoreOS**, as `/home` is to `/var/home`. systemd refuses a
  mount unit whose path is not canonical, so the unit is `var-mnt-media.mount` with
  `Where=/var/mnt/media`. Consumers can still say `/mnt/media`. It fails on a completely healthy
  disk, with `vgs`, `lvs` and `/dev/disk/by-uuid` all looking correct.
- **Quadlet's `Environment=` splits on whitespace.** Compose took a value with spaces as one string;
  quadlet reads the line as space-separated `KEY=VALUE` pairs and **silently truncates at the first
  space**. Three settings were cut on migration - the OIDC scope list, a display name, and gluetun's
  port-forward command. Any literal containing a space must be quoted:
  `Environment="KEY=a b c"`. `${VAR}` references are safe; systemd substitutes those into
  `ExecStart` as single arguments. Audit with: every `^Environment=` line whose value contains a
  space and does not start with a quote.
- **A 302 from an admin route proves the proxy and sign-on, not the service.** An unauthenticated
  request never reaches the backend, so the whole route battery passes with a backend that is down.
  qBittorrent was crash-looping while `torrent` returned a healthy-looking 302. Check backends by
  connecting to them from their own network.
- **Restoring a config taken from a running stack can carry live lock files.** qBittorrent's Qt
  lockfile stores the pid, hostname and machine id; on a host where the hostname does not match, Qt
  assumes the lock is held and qBittorrent **exits one second after starting, logging only
  "termination initiated"** - no error, nothing naming the lock. `bin/backup-config.sh` now excludes
  them.
- **`WebUI\LocalHostAuth` must be `false` for the port-forward push to work**, and it was `true`
  - so `VPN_PORT_FORWARDING_UP_COMMAND` had been getting a 403 and the forwarded port never reached
  qBittorrent. This predates the migration; it came in with the restored config. "Localhost" here is
  inside gluetun's namespace, which only gluetun, qBittorrent and JOAL share, so this is not the
  same as exposing the API.
- **The host is uCore `stable-nvidia-lts`, immutable and rpm-ostree managed.** `/usr` is read-only, so
  host-level tools go in `~/.local/bin` (which is where `sops` and `age` live). Host configuration
  belongs in `host/butane/ucore.bu` - anything applied only over SSH is undocumented state that the
  next reinstall loses. Ignition runs **once, at first boot**, so editing `ucore.bu` does not change
  the running machine; a change has to be applied by hand *and* committed there.
- **`-lts` is the NVIDIA DRIVER branch, not an LTS kernel**, and this is easy to get backwards.
  Both deployments run the identical kernel (`7.1.4-200.fc44`); the rebase moved the driver
  **610.57.04 -> 580.173.02**, NVIDIA's production branch, as deliberate conservatism rather than in
  response to a fault. `rpm-ostree db diff` is what proves it. Anyone "fixing the documentation" by
  reverting the tag to `stable-nvidia` would silently reinstall 610.
- **Zincati and `bootc-fetch-apply-updates.timer` are MASKED, not merely disabled.** Three updaters
  are installed and exactly one may be armed - two would each write a deployment into a `/boot` that
  holds two kernels, and the loser fails overnight with nobody watching. Masking matters because
  `disable` only removes the `.wants` symlink and a `Wants=` elsewhere silently re-enables it, the
  same trap that had `home-server-promote` starting Tdarr every 10 minutes. Masking zincati also
  removes `--bypass-driver` from the migration.
- **`AutomaticUpdatePolicy=stage` is uCore's own default, not something anyone set** - `/etc/rpm-ostreed.conf`
  is byte-identical to `/usr/etc/`. It is restated in `ucore.bu` anyway so the policy is a decision
  in this repo rather than an inherited default that can change underneath it. The only deliberate
  act was enabling `rpm-ostreed-automatic.timer`, whose preset is `disabled`.
- **The OS image ref is `ostree-image-signed:docker://`.** `/etc/containers/policy.json` ships from
  the image with a `sigstoreSigned` scope for `ghcr.io/ublue-os` and both cosign keys in
  `/etc/pki/containers/`, so this needed no file changes - only a rebase. Do **not** ship your own
  policy or key through Ignition: it becomes a permanent `/etc` override that ostree preserves, so a
  ublue key rotation would pin you to a dead key and every update would fail silently. Note the
  `docker` transport has a `""` -> `insecureAcceptAnything` catch-all, which is why ordinary
  container pulls work unverified; a typo'd scope would fall through to it and verification would
  silently pass. `podman image trust show` prints the scope that actually matches.
- **Images follow tags and `podman-auto-update` runs nightly** (since 2026-08-13). Digest pinning was
  dropped because nothing maintained it - thirteen of eighteen images were three months old. See
  `stacks/README.md` for the tag choices, which are the remaining risk control. Two things about it
  are load-bearing and non-obvious:
  - **`Notify=healthy` is what makes the rollback fire.** auto-update restores the previous image
    only if the unit fails to **start**, and systemd otherwise calls a container started the moment
    it runs - so a broken-but-running image passes and nothing is restored. Proven by pointing a
    test unit at a deliberately broken image and watching the journal restore the old one.
  - **auto-update does not trigger a `.build` unit.** Caddy is `AutoUpdate=local`, which notices a
    new image without producing one, and a `.build` unit only runs when its image is absent - so
    without `home-server-caddy-build.timer` Caddy alone would never update. That unit also needs
    `Pull=newer` in `caddy.build`, because podman build's default pull policy is `missing` and it
    would otherwise reuse a stale local `caddy:2` for ever while succeeding in four seconds.
- **The nightly prune does not eat the rollback.** The shipped `podman-auto-update.service` runs
  `podman image prune -f` afterwards, but a superseded image keeps its repository digest and is
  therefore not *dangling* - verified: every pre-update image survived. Only `prune -a` would remove
  them, so **never run that**; the previous image in local storage is the only rollback there is.
- **uCore ships NVIDIA's own `nvidia-cdi-refresh.{path,service}`**, writing `/run/cdi/nvidia.yaml` on
  tmpfs, with the `.path` unit watching `modules.dep` and `nvidia-ctk` so a driver change regenerates
  the spec with no reboot. `ucore.bu` used to define a second unit writing `/etc/cdi/nvidia.yaml`.
  The files were byte-identical, which is exactly why it was invisible - but a spec names the driver
  version in dozens of paths, so the first driver-changing update would have left two files defining
  `nvidia.com/gpu=1` with different library paths, which the resolver **rejects rather than merges**.
  Both Jellyfin and tdarr-node-01 consume that device. Removed 2026-08-13; `bin/verify-host.sh`
  asserts exactly one spec exists and that it names the running driver.
- **`/boot` costs one slot per distinct KERNEL+INITRAMFS, not per deployment**, holds exactly two
  (2 x 146 MB + 11 MB GRUB = 303 MB of 350 MB), and **cannot be grown** - `nvme0n1p4` is XFS, which
  cannot be shrunk by any tool, so enlarging it means repartitioning the disk that carries `config/`.
  Two corrections learned by doing it wrong on 2026-08-14:
  - **`ostree admin pin 0` is wrong whenever something is staged.** Index 0 is then the *staged*
    deployment and the command fails with `Cannot pin staged deployment`. Derive the booted index:
    `rpm-ostree status --json | jq '[.deployments[]] | map(.booted) | index(true)'`.
  - **Pinning the booted deployment is free only until you reboot.** It already owns the slot it
    runs from - but if the deployment you boot into carries a different initramfs, the pin is
    suddenly holding a second full slot. **A firmware bump alone is enough**: the signed rebase
    changed no kernel package, only `linux-firmware` 20260622 -> 20260810, and `/boot` went 171 MB ->
    **26 MB** free until the old deployment was unpinned and `rpm-ostree cleanup -r` run. So
    unpinning after verifying is not tidying, it is what lets the next update write its kernel.
    Reproduced exactly on the 2026-08-14 reboot: 171 -> 26 -> 171 MB.
  - **A low `/boot` WITH something pinned is a different finding from a low `/boot` on its own**, and
    `verify-host.sh` now distinguishes them: the first is a WARN naming the remedy, the second is a
    FAIL. Conflating them cost a false alarm on the first scripted reboot - the pin the script had
    just set tripped the check, and the script concluded the new deployment was bad and recommended
    a rollback. **`bin/reboot-host.sh` gates on `verify-host.sh --greenboot`, not the full battery**,
    for the same reason: containers, backups and the checkout can all be unhealthy for reasons a
    rollback would not fix.
- **`ExecMainExitTimestamp` is runtime state and a reboot wipes it**, so "this nightly job has never
  run" and "it has not run in the twenty minutes since boot" look identical. `bin/verify-host.sh`
  therefore only treats a missing run as a finding once uptime exceeds the timer's period -
  otherwise every reboot produced a day of false warnings, which is precisely how someone learns to
  ignore the one line that matters.
- **`/mnt/media` is a single disk with no redundancy**, holding only re-downloadable media. It is
  treated as disposable and is deliberately not backed up. `config/` is the part that matters.
- **Transcode scratch must stay off the media disk.** `DOCKER_VOLUME_CACHE` points at the SSD
  because the Tdarr node would otherwise read source media and write scratch to the same spindle and
  contend for seeks. Do not "simplify" it back under `DOCKER_VOLUME_MEDIA`.
- **`nv-patch.sh` has been deleted, and should not come back.** It lifted the NVENC
  concurrent-session limit, which NVIDIA raised to 8 for consumer GPUs in Jan 2024, and two Tdarr
  nodes cannot reach that ceiling. On an immutable host, patching a driver library in `/usr` would
  fight OSTree every update.
- **`config/` is on `nvme0n1p4`, not `p3`.** `p3` is the 350 MB `/boot`; `p4` is the 233 GB `/var`
  that carries the OS, the checkout, `config/` (5.6 GB) and now `/var/backups`. `/mnt/media` is a
  separate 7.3 TB XFS volume on LVM on `sda` and survives a reinstall only because it is a different
  device. The pre-migration numbering said `p3`, and the uCore install repartitioned. **Back up and
  verify a restore before booting any installer** - `bin/verify-restore.sh` is now what does the
  second half of that.
- **The bridge is no longer flat, and the forbidden edges are verified.** FlareSolverr cannot reach
  Sonarr on either of its addresses, nor the torrent namespace, tested by IP from inside the
  container rather than by name resolution alone. Jellyfin, the Tdarr nodes and DuckDNS are
  likewise sealed off. **The applications' own logins must still stay enabled**: segmentation is
  defence in depth, and `net-arr` remains flat *within itself* - anything on it reaches every other
  member. See Target architecture for when `AuthenticationMethod=External` becomes defensible.
- **The remaining internal exposure is Prowlarr.** It is the only service on `net-solver`, so it is
  the single hop between a compromised FlareSolverr and everything else. That is the reason its own
  login matters more than the others', not less.
- **SMT is on, and that is a decision rather than a default.** FCOS ships
  `mitigations=auto,nosmt`, which left 6 usable threads of 12 on the i7-8700K - silently, since
  `lscpu` still reports 12 CPUs while `nproc` says 6 and cores 6-11 sit in the offline list.
  `host/butane/ucore.bu` now removes it. **The mitigation it disables is not theoretical here**:
  `nosmt` defends against cross-thread side-channel attacks, which need hostile code on a sibling
  thread, and FlareSolverr runs attacker-controlled JavaScript in headless Chrome by design. The
  judgement is that `net-solver` isolation is the barrier that matters and the threads are worth
  more. If that stops looking right, the `kernel_arguments` block is the thing to revert.
- **Gluetun's HTTP and Shadowsocks proxies are off** (`HTTPPROXY=off`, `SHADOWSOCKS=off`) and the
  container publishes no host port at all. They were unauthenticated and bound to `BIND_LAN`, which
  made them an open proxy into the VPN for any LAN device. Turning them off was cheaper than
  giving them credentials nothing used.
- **Services must address each other over their shared network, never a public hostname.** Flood was
  configured with `https://torrent.avanserv.com`, so its polling left the network and came back
  through the proxy - and stopped working entirely once that route required a session. A container
  reaching another container through the front door is always a mistake; it is slower, it depends
  on DNS and NAT hairpinning, and it breaks the moment authentication is added.
- **Tinyauth now obeys that rule.** Its `TOKENURL` and `USERINFOURL` are `http://pocket-id:1411/...`
  on `net-ingress`; only `AUTHURL` and `REDIRECTURL` stay public, and they have to, because the
  browser is what follows them. Sign-on no longer depends on NAT hairpinning. The feared `iss`-claim
  mismatch did not materialise.
- **A container's stdout is journal priority 6; its stderr is priority 3.** That is podman's
  journald driver, and it means an application that logs to stderr has every line - access logs,
  successful 200s, cheerful startup banners - recorded as a journal **error**. Caddy and Tinyauth
  both did, at ~1950 lines a day, which is enough to make `journalctl -p err` worthless and any
  alerting built on it worse than nothing. Caddy is now pointed at stdout in *both* the global block
  and the `(base)` snippet; Tinyauth's duplicate HTTP stream is off and its audit stream is on.
  **Check where a new service logs before trusting a priority filter.**
- **`journalctl -p err` is STILL not a usable signal, and this entry used to imply otherwise.**
  Fixing Caddy and Tinyauth fixed the two services that had a knob for it. Measured on 2026-08-14,
  what is left: **Jellyfin emits 2,644 priority-3 lines a day** that are ffmpeg decoder chatter
  (`Duplicate POC in a sequence`), and unpackerr another 228 that are s6-overlay `info:` messages at
  startup. Both are the container writing to stderr, neither application can be told otherwise from
  outside, and `LogDriver=`/`LogOpt=` do not remap priority. **So alerting keys on unit state and
  container health - which is what `status.json` carries - and priority is at best a secondary
  filter with a known-noisy allowlist.**
- **Podman emits a `health_status` event per check, carrying the image's whole label set** - the
  Jellyfin one is ~1.5 KB, and the median is 3.8 KB. Sixteen containers at 30s tripled journal
  volume, so the interval was cut to 60s (120s for the Tdarr nodes, 5s for gluetun, the
  kill-switch). **That helped and was not enough.** Measured over a 3-hour full-field
  `journalctl -o export` on 2026-08-14: 34,738 events a day, **47.3% of all journal bytes**, every
  one of them saying `healthy`. They are now off entirely - `healthcheck_events = false` in
  `host/containers/containers.conf` - which drops only `health_status` and keeps every lifecycle
  event. See "Logs and status" below for what that costs.
- **The media disk gets SLOWER with concurrency, and this is measured.** O_DIRECT sequential reads
  off `sda`: **1 reader 127.5 MB/s, 2 readers 70.9 MB/s aggregate, 3 readers 71.4, 4 readers 66.5.**
  Going from one reader to two costs **45% of total throughput** and quadruples `await` (7.7->28 ms).
  Three readers on the *same* LBA region run at full speed (124.7 MB/s), 6 GiB apart inside one file
  costs 37%, three different files 40% - so **the penalty is head travel, not filesystem layout**,
  and no readahead or scheduler change will fix it. This is why the answer to "it's slow" here is
  *fewer* concurrent jobs, not a bigger bandwidth cap.
- **Tdarr's spindle reads are a burst at job ingest, not a sustained load.** Sampled mid-transcode,
  `tdarr-node-01` read **0.00 MB/s from `sda`** and 16.8 MB/s from the NVMe: it stages the source
  into its cache work directory and then works entirely from SSD. Limit concurrency, not bandwidth.
- **JELLYFIN is the stack's largest CPU consumer, and it is not serving anybody.** **Trickplay has
  its OWN hardware-acceleration switches, independent of playback's**, and all three shipped off:
  `EnableHwAcceleration`, `EnableHwEncoding` and `EnableKeyFrameOnlyExtraction` were `false` in
  `config/jellyfin/system.xml` (with `ProcessThreads=1`), so every frame of every file was decoded
  on the CPU - `ffmpeg -loglevel error -threads 1` with no `-hwaccel` anywhere. One file took ~20
  minutes; 223 of 485 were done, leaving **~87 hours** still to run. `cpu.stat` showed `nice_usec` at
  **92.5% of all Jellyfin CPU**, and systemd logged 9h37m of CPU over 15h38m wall. It runs at
  `nice 10` so it does not directly delay the UI, but it streams whole files off the spindle
  continuously. **`podman stats` showing Jellyfin near the top is this, not usage.**
  `EnableKeyFrameOnlyExtraction` is the big lever - it stops decoding every frame.
- **Playback hardware decoding was NEVER off, and the way that was misdiagnosed is the lesson.**
  `grep -E 'HardwareDecodingCodecs' encoding.xml` prints the opening and closing tags on adjacent
  lines and hides the seven `<string>` children between them, so it reads as an empty element. It is
  not: h264, hevc, vc1, av1, vp9, vp8 and mpeg2video are all enabled, confirmed against
  `/System/Configuration/encoding`. **Read a config through the API, or with `sed -n '/<tag>/,/<\/tag>/p'`
  - a line-matching grep cannot show you an XML element's contents.**
- **An IRREGULAR KEYFRAME INTERVAL breaks browser playback, and the symptom names neither cause.**
  Watching *Backrooms (2026)* in Chrome, the picture jumped forward a few seconds at 42:18 and the
  subtitles then no longer matched the audio; reloading the page fixed it until the next time. That
  is not corruption - the file is clean, all streams start at 0.000, no `Non-monotonous DTS`, and
  ffmpeg's frame count matches its playlist to 0.1 s. It is two grids disagreeing:
  - **Jellyfin plays an MKV in a browser as DirectStream** - `-codec:v copy`, audio E-AC3 to AAC
    because Chrome cannot decode E-AC3, packaged as fMP4 HLS.
  - **Its playlist advertises one segment per source keyframe**, from the `KeyframeData` table in
    `jellyfin.db`, because `AllowOnDemandMetadataBasedKeyframeExtractionForExtensions` lists `mkv`.
  - **ffmpeg is told `-hls_time 6` and can only cut on a keyframe**, so it MERGES consecutive
    shorter GOPs. Segment N stops being segment N from the **second segment of every session**, and
    the error accumulates: measured +3.838 s after one segment, +22.397 s after twenty-five.

  So `currentTime` stops matching the picture. Text subtitles are stripped from the stream
  (`-map -0:s`) and timed against `currentTime`, which is why they detach and stay detached, and why
  a reload - a fresh ffmpeg whose first segment is aligned - appears to fix it.

  **We caused it.** `hevc_nvenc` with no `-g` uses a 250-frame cap plus scene-cut I-frames; this
  file's keyframes ran 0.375 s to 10.427 s apart. The plugin now pins the interval - see The
  transcode policy. **`bin/verify-media.sh` is the check**, and it found **9 of the first 10 films
  affected**, so this is library-wide rather than one bad encode. *Flow (2024)* passes with a flat
  10.000 s grid, because it is a restored original that our pipeline never re-encoded.

  Three things that will waste time if not written down:
  - **Throttling is not the cause.** `EnableThrottling` does fire (`Transcoding is paused. Press [u]
    to resume.`), and it only pauses a process - it moves no timestamp, and the drift is measurable
    inside one uninterrupted session. It was the obvious suspect and it is innocent.
  - **The `-ss` values in the FFmpeg logs are `keyframe + 0.500 s` exactly, and that is by design.**
    `-noaccurate_seek` snaps back to the keyframe. It looks like a systematic half-second error and
    is not; do not chase it.
  - **The fix only applies to files encoded after it.** Everything already in `transcoded/` keeps
    its irregular grid. A native Jellyfin client direct-plays the MKV with no HLS involved, so the
    problem is browser-only, which is why re-transcoding the library has not been done.
- **Jellyfin sits AT its `MemoryHigh` with a fast-climbing throttle counter, and that is FINE.**
  `memory.current` 3.00G against `MemoryHigh=3G`, `MemoryPeak` **2 MB above the watermark**, and
  `memory.events` `high` at 6,398 within seven minutes of a restart. It looks exactly like the
  `tdarr-node-01` problem, and **it is not the same thing** - `MemoryHigh` was deliberately left at
  3G after measuring. What settles it is `memory.stat`, not the event counter:

  | | Jellyfin |
  |---|---|
  | `anon` (its actual working set) | **0.385 G** |
  | `file` / of which `inactive_file` | 2.543 G / **2.338 G** |
  | `pgscan` vs `pgsteal` | 2,776,855 vs 2,776,829 |
  | `memory.pressure some` | **avg10/60/300 all 0.00**, 65 ms total stall, ever |

  Jellyfin needs under 400 MB. The rest is cold, clean page cache from streaming media, which the
  kernel reclaims at essentially zero cost - `pgsteal` tracks `pgscan` to five digits, so every page
  scanned is successfully freed, and nothing ever stalls. **A cgroup doing file I/O will always sit
  at its `MemoryHigh` and always accumulate `high` events**, because that is what the watermark is
  for; raising the ceiling would only let more cold cache pile up before the same free reclaim.
  **`memory.events high` on its own proves nothing. Read `anon` vs `inactive_file`, and read
  `memory.pressure`** - real starvation shows a large `anon`, `pgsteal` falling short of `pgscan`,
  a climbing `workingset_refault_file`, and nonzero pressure.
- **Jellyfin 10.11's own queries are slow, and it is not this stack's fault.** The real home-screen
  query takes **29-79 ms in-container** for a 522-item library and a 26 KB response, against ~1 ms
  for Sonarr's equivalent, and the log carries EF Core's `Compiling a query which loads related
  collections for more than one collection navigation` warning. Inherent to the 10.11 EF Core
  rewrite. Recorded so nobody re-investigates it as a configuration problem.
- **Two NVENC sessions already pin the encoder block at 100%** while the SM sits at 10%. A third GPU
  worker cannot encode faster; it only adds cache and spindle pressure. Worker limits are therefore
  `transcodegpu:2, transcodecpu:0, healthcheckgpu:0, healthcheckcpu:0`. `transcodecpu` is 0 because
  `libx265 -preset medium` measured **0.54x realtime** - about 4.5 hours a film - while competing for
  the same disk that NVENC's source ingest needs.
- **`queueSortType: sortPathAZ` is how episodes come out in order.** Sonarr names files
  `<Series> - S01E02 - ...` inside `Season 01` folders, so alphabetical path order *is* season/episode
  order. It is a single global setting, not per-library; `prioritiseLibraries` is on so the library
  `priority` field is honoured instead of round-robin.
- **The community "5 steps" flow was actively destructive and is retained only as a rollback.** Its
  audio node ran `-c:a:0 libopus` with **no `-map`**, so exactly one audio track survived - which one
  depended on the stream reorder, so it deleted the French dub on the Harry Potter films and the
  Latvian VO on *Flow*. It ran `mkvpropedit` three times and two full `-c copy` remuxes (27 minutes
  of pure I/O before the first frame), used work directories of **53 GB per worker** where the
  one-pass flow uses **1.0 GB**, and its net effect across all four libraries since 2025-03-15 was
  **-141.6 GB, i.e. the outputs were 141.6 GB larger than the inputs**. 707 of 2027 transcodes
  errored, averaging 44.7 min each. Flows `htpX8Ypt1`...`25kSD__gW` are left in place, unused;
  rollback is pointing a library's `flowId` back at `htpX8Ypt1`.
- **A Tdarr health check is a full-file decode, not a metadata read**, and queueing 470 of them took
  the whole host down. Moving 470 episodes into a watched folder was enough: that is the entire
  library read end to end off one 7200rpm spindle. **The kernel stayed healthy throughout** - it
  answered ICMP and completed TCP handshakes on 22, 80, 443 and 8096 the entire time - while no
  userspace process could be scheduled. sshd never got far enough to send a banner; Caddy and
  Jellyfin accepted connections and answered nothing. With no console, it took a power cycle.
  **A wedged box and a healthy one are indistinguishable from a ping.**
- **`io` is NOT delegated to the user manager by default; `cpu memory pids` are.** An undelegated
  controller is accepted silently and does nothing, so every `IOWeight=` and `IOReadBandwidthMax=`
  in `stacks/` was inert - the control aimed squarely at the cause above was the one not working.
  `host/butane/ucore.bu` now ships `/etc/systemd/system/user@.service.d/10-delegate-io.conf`. It
  takes effect on `daemon-reload` with no session restart. `sda` runs BFQ, which is what makes
  `io.weight` meaningful rather than advisory. **Verify rather than assume - the failure is silence:**
  `systemctl show user@1000.service -p DelegateControllers`.
- **Every service quadlet carries `MemoryHigh`/`MemoryMax`**, and the Tdarr units additionally carry
  `CPUWeight`, `IOWeight` and `IOReadBandwidthMax`. These are systemd cgroup directives in
  `[Service]`, not podman flags, because a quadlet *is* a systemd unit and that is the layer that
  can starve it. Ceilings are sized to catch a runaway, not to tune anything.
- **Tdarr is back in `default.target` and running.** There are **two** units, `tdarr-server` and
  `tdarr-node-01`; both carry `WantedBy=default.target` and both come up at boot. There is no
  `tdarr-node-02` - it existed only in the deleted Compose file. This entry used to say all three
  were commented out and stopped, pending throttles; the throttles are in place (worker limits
  `transcodegpu:2, transcodecpu:0`, `CPUWeight`/`IOWeight`/`IOReadBandwidthMax`, and the `io`
  controller actually delegated) and the units were re-enabled. **The warning that came out of that
  period still stands: a `Wants=` on a disabled unit silently re-enables it**, which is how
  `home-server-promote.service` started Tdarr every 10 minutes. `After=` for ordering, never
  `Wants=`.
- **The ISP resolver returns a blocking page for several indexer domains.** All three distinct
  1337x hostnames resolved to one address, `193.191.210.104`, and four indexers failed as "DNS/SSL
  issues" while every container looked healthy. `prowlarr` and `flaresolverr` therefore carry
  `DNS=9.9.9.9` / `DNS=1.1.1.1`. Measured from a throwaway container: the request that dies at the
  sinkhole reaches the real Cloudflare-fronted host and returns a 403 challenge, which is exactly
  what FlareSolverr is on `net-solver` to solve. **A DNS failure here looks like an application
  fault, so compare a suspect hostname against a public resolver before believing the site is down.**

## Target architecture

**Steps 1 and 2 are done.** The host is uCore `stable-nvidia-lts` and every service is a rootless
Podman quadlet: `network_mode: service:gluetun` became a Podman pod, `runtime: nvidia` became CDI
device refs, and every bind mount carries `:z`/`:Z` except `/mnt/media`, which is labelled once at
mount time by `context=` instead of relabelling 7.3 TB per container start.

Doing ingress, segmentation and secrets on the Compose stack first was the right call, but not for
the reason given at the time. The claim was that their configuration would "carry over unchanged".
**It did not** - segmentation had to be rebuilt with `isolate=true` because netavark does not
inherit Docker's inter-bridge isolation, and ingress needed firewalld rules that Docker made
unnecessary. What carried over was the *design*, and the fact that it had been proven to work: when
FlareSolverr could reach Sonarr on the new host, the question was "why is this different here",
not "was this ever right".

**Step 3 is done.** `bin/backup-offsite.sh` copies the repository to Scaleway Object Storage with
its own password, and both age keys and both restic passwords are in the password manager - which
was the actual gap, since the alternative was an off-site backup nobody could decrypt.

**Step 5 is done, and it replaced the pinning rather than building on it.** The old wording here
claimed digest pinning was auto-update's *prerequisite*; that was backwards. `AutoUpdate=registry`
resolves a tag, so a digest makes it a no-op - the two are alternatives, and the pinning was
abandoned because nothing maintained it. See `stacks/README.md`.

Remaining, in order:

1. **Monitoring**, so a failed unit surfaces without someone running `systemctl --user --failed`.
   `bin/verify-host.sh` and its MOTD cover the specific things automation puts at risk - a staged
   deployment nobody applies, an update run that silently stopped, a CDI spec that no longer matches
   the driver, a backup that has stopped running, a checkout that has drifted from git.

   **The data layer is done, 2026-08-15.** `/var/lib/home-server/status.json` carries every finding
   keyed by a stable id, plus a `facts` object of the numbers, rewritten hourly - see "Logs and
   status". The journal is declared and bounded at 90 days, and 47% of its volume (podman's
   `health_status` events) is gone. **The durable-record gap named below is closed**: `status.json`
   carries `generated_at` and lives where a reboot does not reach, so this script finally has the
   marker every other job already had.

   **What is still missing is anything that reaches a human who is not logged in.** That is now the
   whole of this item. The dashboard reads `status.json`; a notifier would fire off the same
   document, or off an `OnFailure=` on `home-server-verify.service`.

   **Do NOT build it on `journalctl -p err`.** Jellyfin alone emits 2,644 priority-3 lines a day of
   ffmpeg chatter and there is no lever to stop it - see Known state. Unit state and container
   health are the signal. Note also that `duckdns` and `unpackerr` never report health - neither
   serves HTTP - so a check assuming every container has a health status reports them broken for
   ever.

   **The generalisable lesson from the backup work: an automated job needs a durable record of its
   last success, not just a unit that exits 0.** `ExecMainExitTimestamp` is wiped by a reboot, and a
   pull-based job leaves no trace on the machine being watched at all. Anything added here should
   write its own timestamp somewhere `verify-host.sh` can read.
2. ~~greenboot, and only then an unattended reboot window.~~ **Done, 2026-08-14.** See
   `host/greenboot/README.md`. greenboot is layered - the one package on this host, and a
   deliberate exception to the rule below - and a rejected deployment rolls itself back. The
   reboot window is `home-server-reboot.timer`, hourly from 05:00 to 09:00 on Sundays, driven by
   `bin/reboot-when-staged.sh`, which is nothing but refusals - with one deliberate exception.

   **A gate that is correct every time can still be wrong in aggregate, and the encoder gate
   was.** It refuses while a transcode is running, which is right, but the window was a single
   instant and Tdarr jobs run for tens of minutes - so one busy minute cost the deployment a
   whole week, and a queue that stayed busy could do that indefinitely while every individual
   refusal remained defensible. Two changes, both needed: **five attempts across the morning**,
   so a transcode finishing at 05:30 does not cost seven days; and **an escalation** - past 14
   days staged or 30 days of uptime, the encoder stops being a veto and the transcode is killed.
   The trade is named rather than implied: a killed transcode is a *cost* of one hour of GPU
   time against a source that is hardlinked in `downloads/` and untouched, while another month
   on an unapplied image is a *risk*. Two clauses because they fail differently - the staged
   age resets whenever a new image supersedes the old one, so on a weekly release stream it
   could never reach 14, and only uptime cannot be starved.

   **The rollback is proven, not assumed**, by layering `tree` to make a second deployment and
   rejecting it: four red boots, then `Rollback successful`, then a clean boot on the deployment
   without `tree`, seven and a half minutes unattended. Three things that cost real time and
   would cost it again:

   - **GRUB boot counting does not work on FCOS out of the box, and its absence is silent.**
     greenboot ships its snippet to a bootupd *source* directory that layering never regenerates,
     so the counter is armed and never counted down: checks run, journal reads healthy, rollback
     cannot happen. `/boot/grub2/custom.cfg` is what closes it.
   - **greenboot reboots the machine itself on a red boot.** The unit files say otherwise - no
     `OnFailure=`, no `redboot.target` - and every one of those facts is true and leads to the
     wrong conclusion, because the behaviour is in the binary. Reasoning from unit files about
     what a program does is how a whole afternoon gets spent.
   - **A system unit, or a drop-in for one, cannot be a symlink into `/var/home-server`.**
     SELinux is Enforcing and the checkout is `var_t`, so PID 1 cannot read it - while
     `systemctl cat` prints the file happily and no AVC is logged. The check scripts *are*
     symlinks and correctly so: greenboot execs those itself. What systemd launches or parses
     must be labelled; what a running process then reaches is free.

**The applications keep their own logins.** Segmentation narrowed who can reach them; it did not
reduce `net-arr` to a single caller, so `AuthenticationMethod=External` would still trust five
containers rather than just Caddy. Revisit it only if those segments are split further, and note
that their *"Disabled for Local Addresses"* option is never the right tool here: Caddy and every
other container are RFC1918 addresses, so it disables authentication for precisely the attacker
path.

**Avoid host-level package dependencies.** `/usr` is read-only and every layered package makes the
next rebase slower and able to fail on dependency solving - which is why `nv-patch.sh` was deleted,
and the reason greenboot is a gate rather than a given.
