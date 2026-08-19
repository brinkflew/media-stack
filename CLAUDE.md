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
| `docs/` | what was learned the hard way. `known-state.md` is the one this file indexes. |

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
the packets are simply taking a long way round.

**Split-horizon DNS would fix it, and was CONSIDERED AND DECLINED on 2026-08-15.** Recorded here
because the measurement above reads like a pending action item and will otherwise be re-proposed
every time someone rediscovers it. Three things settled it:

- **It is not perceptible.** 5x on a number that starts at 12 ms is still under a tenth of a second,
  and nobody browsing has ever noticed. The measurement is real; the complaint was theoretical.
- **A blanket override is unavailable.** `*.avanserv.com` serves a DIFFERENT machine, so the
  override cannot be `avanserv.com` -> `192.168.0.100`; it has to enumerate the twelve hostnames
  Caddy answers for. That is a second list of the Caddyfile's site blocks, maintained by hand, in a
  place nothing validates - the most driftable shape this repository has a name for.
- **Both places to put it are worse than the problem.** On the router it is unversioned state this
  repo cannot see, verify or restore, which is the whole reason `host/butane/ucore.bu` exists. On
  the server it is a resolver container the whole house then depends on for DNS, so the machine
  going down stops being "the media stack is offline" and starts being "the internet is broken".

It would also silently change what `bin/verify-host.sh --routes` measures, since that battery
resolves the same public names from the server itself - it would stop proving the WAN path and
nothing would say so.

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

**Five things the backup does that a plain `rsync` does not**, each of which otherwise produces a
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
- **The metrics store is snapshotted through Prometheus' admin API**, not copied, and excluded from
  the rsync that would otherwise copy it. `/api/v1/admin/tsdb/snapshot` makes the snapshot out of
  **hardlinks**, so it is instant, costs no disk and is consistent at the instant it is taken - the
  same argument as SQLite's backup API one bullet up. The step deletes its own snapshot and clears
  stale ones, because Prometheus never reaps `snapshots/` and `--storage.tsdb.retention.size`
  manages blocks only; a leaked one grows real disk inside the directory `metrics.tsdb_size`
  measures and gets reported as "retention is not being enforced".

**THE EXCLUDE LIST DID NOT COVER THE TSDB, AND COULD NOT SAY SO.** This is the sharpest instance yet
of a pattern this repository keeps rediscovering, and it was shipped and caught the same evening:

- Prometheus names its lock file **`lock`**. `lockfile` does not match it, and neither does
  `*.lock`. Its write-ahead log is a **directory** called `wal/`, which `*-wal` does not match.
  Verified on the live host: **zero hits for every pattern in the list.** The live store, open WAL
  and lock included, was being copied whole.
- **And it does not merely produce a torn copy, it aborts the run.** Prometheus deletes WAL segments
  at every checkpoint and source blocks after every compaction; `rsync` exits **24** when a file it
  has already enumerated vanishes, and that line ends in `|| die`. One routine compaction inside the
  backup window kills the job **before** the certificate assertion, the database snapshots, both
  restic legs and the marker write - surfacing as `backup.local_age` going stale, three scripts away
  from the cause. `bin/backup-config.sh` carried the same list under `set -e` with no handler at all.
- **A pattern list that silently matches nothing looks exactly like one that works** - the same
  shape as the shellcheck leg that reported `all checks passed` over 2,224 lines it had never
  looked at. When adding an exclude, check it matches something.
- `--filter='protect /prometheus/'` is what stops `--delete-excluded` deleting last night's staged
  copy and forcing a full re-copy nightly. Tested both ways rather than assumed.

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

## Metrics

**`status.json` answers "is this true now" and nothing else.** It cannot say when a backup started
being stale, whether a container's memory has been climbing for a month, or what the encoder was
doing when the host wedged - and every number this file reasons about was measured by hand, once,
during an incident. Since 2026-08-15 there is a time-series layer: **Prometheus** on `net-metrics`,
behind sign-on at `metrics.avanserv.com`, 400 days at a 30s scrape.

```bash
podman exec prometheus wget -q -O - 'http://127.0.0.1:9090/api/v1/query?query=<metric>' | jq .
/var/home-server/bin/collect-metrics.py --print | head -50   # what the collector produces
jq -r '.checks[]|select(.section=="metrics")' /var/lib/home-server/status.json
```

**The store is Prometheus rather than VictoriaMetrics, and the tag policy decided it.**
VictoriaMetrics is lighter and was the obvious candidate, but it publishes **no `:v1` and no
`:stable`** - only `:latest` and full triples - so `AutoUpdate=registry` would have tracked `:latest`
on the one component holding every byte of history. Prometheus publishes `:v3`. It is also reference
PromQL rather than a superset, so a dashboard query cannot come to depend on an extension by
accident.

**Off the shelf where an exporter measures correctly; bespoke only where one provably cannot.**
node-exporter gives CPU, memory, load, PSI, diskstats, hwmon and vmstat for free.
`bin/collect-metrics.py` covers the remainder, and each item is there for a measured reason rather
than a preference:

| Series | Why it cannot come from a container |
|---|---|
| `node_filesystem_*` | **No rootless container can run node-exporter's filesystem collector.** It reads `/proc/1/mountinfo` for the host mount table, and reading another user's `/proc` entry must pass `ptrace_may_access`: host PID 1 is real root, and rootless Podman maps container uid 0 to `core`. `User=0` does not help. It failed `EACCES` on every scrape, and because that is not `ENOENT` there is no fallback to `/proc/mounts`. |
| `node_network_*` | `/proc/net` is a symlink to `self/net`, so it resolves in the **reader's** network namespace, not the mounted procfs. A bridge-networked node-exporter reports its own container's interfaces while looking exactly like it reports the host's. |
| `home_server_container_memory_*` | cAdvisor exports `memory.current` and stops. Four of the five numbers that settle the "at its ceiling or actually starved" question - `pgscan`, `pgsteal`, `workingset_refault_file`, PSI - have no cAdvisor metric at all. |

**The SELinux objection to containerised exporters was wrong, and it was checked rather than
assumed.** Queried against the loaded policy: `container_t` may read `proc_t`, `sysfs_t` and
`cgroup_t`, and `filesystem getattr` - which is what `statfs` needs - is allowed for `fs_t` and for
`container_file_t`. So node-exporter needs no `SecurityLabelDisable=`, no relabel flag and no new
boolean, and `ausearch -m AVC -ts boot` has stayed empty throughout. **What it cannot reach is the
part that matters**: `container_t -> var_t` FILE READ is DENY, as is `data_home_t`, so the read-only
`/:/host/root` bind mount cannot read `.env`, `secrets/` or the age keys - and DAC refuses a second
time, since those are `0600 core` and the exporter runs as `nobody`.

**Do not "fix" a permission problem here with `:z`.** It relabels the *source*: on `/` it fails
against the read-only ostree `/usr` and destroys the labels it does reach, and on `/var` it would
make the whole checkout readable by every container on the host. The one directory that does take a
label is the textfile drop, which is small and dedicated.

**The failure that is easy to misread: a DAC refusal and an SELinux refusal look identical from
inside a container.** The filesystem collector failing was DAC, with an empty AVC log throughout.
They need completely different fixes, and `ausearch` is what distinguishes them.

**The podman socket is genuinely blocked**, and that is the one real cost. `container_t ->
unconfined_t : unix_stream_socket connectto` is DENY and is not fixable by relabelling, because
`systemd --user` for uid 1000 runs as `unconfined_t`. So no container can have container health
state, restart counts or image metadata - `podman ps` from the host is the only source, which is why
the collector reads it.

**Delivery is node-exporter's textfile collector, not a push, because Prometheus pulls.** That was
not a workaround and it pays for itself twice: `node_textfile_mtime_seconds` dates the file from
**outside** the collector, and `node_textfile_scrape_error` flags a malformed one. The file inherits
`container_file_t` from its directory, so the host writes it and the container reads it.

**There is deliberately no `home_server_collector_up 1`.** A sample asserting liveness can only be
written by something that is alive, so it is a tautology that reads green for ever after the
collector dies - the same trap `verify-host.sh` documents at length about its own timer. The
timestamp is written *into* the file the run produces, so the last value present is by construction
the last success.

**Every check in the `Metrics` section is WARN or PASS, never FAIL**, for the reason the `Logs`
section already gives: `bin/reboot-host.sh` and `bin/reboot-when-staged.sh` refuse to act on a host
this battery calls unhealthy, and a stopped collector must never hold up an OS security update.

**The naming contract: the metric name and its label set are the id; the collection mechanism is the
prose.** Upstream names are adopted only where the semantics match *exactly* - `node_filesystem_*`
is `statfs`, so it is portable back to a real node-exporter the day one can run. Where they only
almost match, a `home_server_*` name is minted instead, because **a wrong number under a right name
is undetectable from a dashboard**, and correcting semantics under a borrowed name silently rewrites
the whole retention window. `home_server_container_memory_high_bytes` exists rather than cAdvisor's
`container_spec_memory_reservation_limit_bytes` for exactly this reason: that one maps to
`memory.low`, not `memory.high`.

**Identity joins on podman's own `PODMAN_SYSTEMD_UNIT` label, never on a name derived from the
container.** That is what makes `torrent-infra` resolve to `torrent-pod.service` with no lookup
table - and a table maintained in a script is the most driftable thing here.
`home_server_container_identity_unresolved` counts what did not map, because the failure is
otherwise silent: a container simply missing from every panel.

**`/` is deliberately not in the filesystem allowlist.** It is the read-only composefs: 8 MB, zero
bytes free, 100% full by design and for ever. A panel showing the root filesystem full would read as
an emergency and mean nothing, and `statvfs` returns -1 for its inode counts.

**Application metrics go through `podman exec`, and the credential goes over stdin.** `curl -K -`
reads its whole configuration from stdin, so an API key never reaches the process list - which
`podman exec ... -H "X-Api-Key: ..."` cannot avoid, and which matters at 288 polls a day where it
did not at two. Prowlarr's and Bazarr's keys were read out of `config/prowlarr/config.xml` and
Bazarr's `config.yaml` rather than fetched from their UIs. **Bazarr's header is `X-API-KEY`, not the
\*arr apps' `X-Api-Key`** - it is not a Servarr application and does not share their API.

**`home_server_indexer_up` is the metric that justified the Prowlarr key**, and it was non-zero on
the first run: 7 of 17 indexers disabled by repeated failures, including all three Pirate Bay
entries and both 1337x ones. That is the shape of the ISP-resolver problem already in Known state -
every container healthy, nothing found, and no other signal anywhere.

**TWO NUMBERS COUNT THE SUBTITLE BACKLOG AND NEITHER IS WRONG.**
`home_server_subtitles_missing{kind="episodes"}` comes from Bazarr's badges and counts missing
subtitle *files*: 1,038. `home_server_subtitles_wanted_items{kind="episodes"}` counts *episodes* with
at least one missing subtitle: 543. Most episodes here want both English and French, so the first is
roughly twice the second. They have different names precisely because a second series called
`subtitles_missing_something` would be indistinguishable from the first on a dashboard - the same
argument `home_server_container_memory_high_bytes` exists for.

**`api_get` TRIES curl AND FALLS BACK TO wget, because two images ship only the latter.** gluetun and
jellyseerr have no `curl`, so every poll against them returned `None` - and since each caller guards
with `if isinstance(x, dict)`, that read as "the endpoint had nothing to say". `home_server_vpn_info`
was therefore **never once emitted** from the day it was written until 2026-08-17: absent from the
TSDB, absent from the dashboard's VPN row, and reported by nothing, because the source still completed
and still wrote `source_up 1`. The fallback keeps the credential off argv by having a shell inside the
container read it from stdin, and `home_server_collector_client_unavailable` now makes the next
instance visible - written as an explicit 0, because a series that only appears when something is
wrong cannot be alerted on with `== 0`.

**The Tdarr file table is a GAUGE and the job table is a COUNTER**, and the type carries the
distinction rather than a comment. `filejsondb` drains to zero by design, so a short table means the
queue is empty; `jobsjsondb` is the durable history and is deliberately **not** pulled, because
`getAll` over thousands of rows every five minutes costs more than it tells anyone.

**The VPN's forwarded port has no readable source here.** gluetun writes no port file unless
`VPN_PORT_FORWARDING_STATUS_FILE` is set, and since v3.40 its control server answers 401 on
everything except `/v1/publicip/ip`. Nothing is lost: gluetun pushes the port into qBittorrent on
every reconnect, so `home_server_torrent_listen_port` carries what that push produced, and
`home_server_torrent_connection_state` reports `firewalled` when the two have drifted - which is the
consequence the port number was only ever a proxy for.

**The slow tier writes its own textfile, and that is not tidiness.** The file is rewritten whole on
every run, so 5-minute series living in the 30-second file would blink out for nine ticks in ten and
render as a sawtooth that looks exactly like a flapping disk. node-exporter globs `*.prom`, so a
second file is simply served unchanged in between.

**Backing up a live TSDB is the trap this arrangement exists around**, and it is documented under
Backups rather than here because it breaks the backup rather than the metrics.

## Alerting

**Since 2026-08-15 something finally leaves the house.** Everything above is only legible to someone
who has already logged in to find out whether anything is wrong, which was the last open item on the
roadmap. The chain is four hops, and each exists for a reason:

```
prometheus --rules--> alertmanager --webhook--> ntfy-alertmanager --> ntfy --> phone
```

```bash
podman exec prometheus wget -q -O - http://127.0.0.1:9090/api/v1/rules | jq -r '.data.groups[].name'
podman exec alertmanager wget -q -O - http://127.0.0.1:9093/api/v2/alerts | jq length
podman exec alertmanager amtool --alertmanager.url=http://127.0.0.1:9093 silence add <matcher>
```

**Alertmanager rather than a script polling `status.json`**, because three of its behaviours would
otherwise have been reinvented badly: **grouping**, so twenty checks failing at once is one
notification; **repeat suppression**, so a condition that stays true does not notify every 30
seconds; and **resolution**, so you are told when it stops. The first two are what decide whether a
channel is still being read in six months - the same argument this file already makes about
`journalctl -p err`. `repeat_interval` is **12h for warnings, 4h for critical**.

**`CheckFailing` covers all 159 check ids and every future one - but only at FAIL.** Its expression
is `home_server_check_status == 3`, so **a check that is deliberately WARN never notifies**, and
several here are WARN precisely because they must not block a reboot. Usually that is right: a WARN
belongs in the MOTD and the dashboard, not on a phone. Where it is not - `deploy.image_digest`,
which is WARN so that a stalled updater cannot block the OS updates it is complaining about not
getting - **the check needs a targeted rule of its own** (`OsImageStale`, `== 2`, `for: 6h`).
Adding a WARN check and expecting the generic rule to carry it is the silent half of this.

**The bridge is the only image here with no rolling major tag**, which is the objection that ruled
out VictoriaMetrics for the store. It is accepted on a distinction that holds: VictoriaMetrics would
have held every byte of history, and `ntfy-alertmanager` holds **nothing** - it is stateless glue
with an in-memory cache, so a bad unattended update costs a restart rather than a retention window.
ntfy has no native Alertmanager receiver and is not about to: its own documentation lists four
third-party bridges and no first-party option.

**Its health check asserts a 401, not a 200, and that is the interesting part.** The only endpoint
is the webhook, so there is nothing to GET successfully - but a 401 proves the process is up, the
config parsed *and* that basic auth is switched on. A check that accepted any response would go
green against a bridge that had silently lost its credentials.

**`ntfy` is the third route that skips sign-on**, alongside `watch` and `request`, for the identical
reason: the client is an app with no browser in which to complete a passkey prompt. It authenticates
its own users instead, `auth-default-access` is `deny-all`, and **neither declared account is an
admin** - the phone's account is read-write on one topic, the publisher's is write-only on the same
one. Proven rather than assumed: anonymous publish 403, publisher read 403, human read 200.

**Two containers here read a config file and substitute nothing in it**, the same trap
`prometheus.yml` already documents. `bin/render-template.py` writes both from tracked templates plus
`.env`. It exists because a **bcrypt hash cannot travel through `Environment=`**: it is full of `$`,
and it would cross systemd's expansion and ntfy's own `$$` unescaping, so the value in sops would
have to be double-escaped and would stop matching what `ntfy user hash` printed.

**THE FIRST RULE GROUP IS NOT OPTIONAL, AND IT IS FIRST.** Every other rule reads a series that
arrives through node-exporter's textfile collector, and **a rule whose expression matches nothing
does not fire** - so if the collector or the scrape stops, the whole battery goes silent, and silence
is exactly what healthy looks like. Same trap `verify-host.sh` documents about its own timer, and the
same reason there is deliberately no `home_server_collector_up 1`. `TargetDown`,
`MetricsCollectorStale`, `VerifyBatteryStale` and `AlertDeliveryFailing` cover it.

**Nothing can notify you that the notifier is down**, and the design says so rather than pretending
otherwise. `AlertDeliveryFailing` fires so that it is recorded and arrives when delivery recovers;
the channel that actually covers a dead notifier is out-of-band - `metrics.alert_rules`,
`metrics.alertmanager_up` and `metrics.alert_delivery` in `verify-host.sh`, which reach the MOTD and
`status.json`.

**Degradation alerts are deliberately slack, and two of them are aggregates rather than per-item.**
Any single indexer or subtitle provider backing off is ordinary - a free daily quota runs out most
days - so the rules fire on `sum(...) == 0` for providers and on fewer than half the indexers being
up. The failure mode being designed against is not missing one, it is sending enough of them that the
critical ones stop being read.

**`systemctl --user reload prometheus` needs `ExecReload=`, not `ReloadSignal=`.** The latter is only
honoured for `Type=notify-reload` and quadlet generates `Type=notify`, so systemd accepts the
directive and refuses every reload with *"Job type reload is not applicable"*. It had never once
worked.

**Check rules before deploying them.** A malformed file makes the reload fail and leaves the previous
rules running - safe, but not what you asked for:

```bash
# NOTE the `sh -c`: podman exec runs no shell, and promtool does not glob itself,
# so the bare form fails with "path does not exist" and reads like a missing mount.
podman exec prometheus sh -c 'promtool check rules /etc/prometheus/rules/*.yml'
podman run --rm -v "$PWD/apps/alertmanager/alertmanager.yml:/c.yml:z" \
  --entrypoint amtool quay.io/prometheus/alertmanager:v0 check-config /c.yml
```

**None of that proves delivery, and the deployment proved it the hard way.** Alertmanager named its
webhook password on `/etc/alertmanager` - the read-only `apps/` mount, where `ExecStartPre=` cannot
write it - while the rendered file sat in `/alertmanager`. Every container healthy, both configs
`SUCCESS`, Prometheus discovering the Alertmanager, and every notification failing with a 401
recorded nowhere but Alertmanager's own log. **Fire a real alert and look for it at the other end.**

## The dashboard

**Since 2026-08-15 there is somewhere to look that is not an ssh session.** A Vue 3 application at
`home.avanserv.com`, behind the same passkey sign-on as everything else, built from
`apps/dashboard/` and served by its own container. It closes the last roadmap item: `status.json`
for what is true now, Prometheus for when it stopped being true.

```bash
systemctl --user start home-server-dashboard-build.service   # the deploy; see below
cd apps/dashboard && npm run dev                             # fixtures, no server needed
```

**All five pages are built.** System and Services were the first cut, on 2026-08-15; **Home and
Library landed 2026-08-17** and needed a data layer before they needed a design. **Network split out
of Services on 2026-08-18**, and needed a measurement that did not exist - see below.

**It is READ-ONLY, and that is structural rather than a v1 shortcut.** The design has restart, pull,
approve and terminate buttons, and no container here can have them: `container_t -> unconfined_t :
unix_stream_socket connectto` is DENY and is not fixable by relabelling. Actions need a privileged
host-side surface reachable from a browser, which is a decision to take on its own merits. **Every
one of those chips is a deep link into the owning application instead**, which keeps the design's
layout slot and is what its own fallback chip already did - `src/links.ts` holds the mapping, derived
from `window.location.hostname` so no build-time variable is involved.

**Five sources, and the split is the point:**

| Source | Carries |
|---|---|
| **Prometheus**, proxied same-origin at `/api/prom` | every number and every history, including `home_server_container_info{container,unit,image,pod}` - podman's own identity join, so the pod rack needs no lookup table |
| **`status.json`**, served as a file at `/data/status.json` | the **prose** of the findings. The metric carries the verdict and deliberately not the message; the id is the join |
| **`activity.json`**, every 30s | what is playing and what is in flight, **with titles** - sessions, downloads, transcodes, torrents |
| **`library.json`**, every 5 minutes | requests, recently added, recent completions, stalled and queued files, the subtitle backlog |
| **`apps/dashboard/src/topology.ts`**, compiled in | the segment rails and the published-port table. The topology *is* static - it is `stacks/`, in git - and only the node colouring is live |
| **`apps/dashboard/src/paths.ts`**, compiled in | who talks to whom. Half of it lives in an application's own database, so it is **validated** rather than derived |

**THE TWO DOCUMENTS EXIST BECAUSE A TITLE CANNOT BE A PROMETHEUS LABEL, AND THE SECOND REASON IS THE
ONE THAT MATTERS.** Cardinality is the obvious one. The real one is that `source_playback` refuses to
label a session with the user, the device or the item, because a 400-day series of who watched what
is surveillance of the household rather than monitoring of a machine. Home needs exactly that to draw
a now-playing card, so it travels as a document: **rewritten whole every run, with no history
anywhere.** That difference is the whole justification, and the moment any of it grows a retention
window the refusal has been reversed by accident.

Split by **cadence, not by page** - both pages read both - for the reason `home-server-slow.prom`
already records: a five-minute slice in a thirty-second file blinks out nine ticks in ten and renders
as a sawtooth that looks exactly like a fault. **`sources` is not optional** in either: one
`{ok, at, error}` per upstream consulted, because otherwise "jellyseerr timed out" and "there are no
pending requests" are the same empty list. It is `mode.routes: false` applied to applications.

**POSTERS COME SAME-ORIGIN AND CARRY NO CREDENTIAL, which is measured rather than assumed.** Jellyfin's
`/Items/*/Images/*` answers 200 unauthenticated while every other path on it answers 401 - checked
from inside the Caddy container - so `home.{$DOMAIN}` proxies exactly that, GET and HEAD only,
path-guarded to a 32-hex item id, and a mis-scoped matcher fails closed into Jellyfin's own 401 rather
than opening its API. Not `watch.{$DOMAIN}`: cross-origin, 30-60 images a load through NAT loopback at
the measured 5x, and a poster grid hanging off a route deliberately outside sign-on. Only a **tagged**
request gets a long cache, because the tag is a content hash and an untagged URL is whatever the image
happens to be now. **Test those guards with `curl`, not `caddy validate`** - see the warning that
block already carries.

**An almost-empty Library table is the NORMAL, HEALTHY rendering**, and the page is built for that
rather than for the mock's 47 rows. `queued/` holds no video files because `promote-transcoded.py`
works, and Tdarr's file table drains to zero by design. So there are three empty states saying three
different things, and the important one is that **stale-and-empty reads "no rows as of 8m ago", never
"nothing in flight"** - at eight minutes old that is an assertion nobody is entitled to make. Same
distinction as rendering `mode.routes: false` as "not measured".

**`status.json` is COPIED into a served directory, not mount-mapped, and `:z` cannot fix the
alternative.** The canonical file is written through `sudo`, so it is root-owned inside a `var_lib_t`
directory that `container_t` may not read - and relabelling on a rootless mount is performed by the
*invoking* user, so `chcon` fails `EPERM` because `core` does not own `/var/lib/home-server`. The
mount is accepted and the container gets permission denied. `bin/verify-host.sh` therefore writes
the same bytes a second time, as `core`, into `${DOCKER_VOLUME_CACHE}/dashboard/`. That is the same
shape as node-exporter's textfile drop, which is the one directory here that may safely take a label.

**There is deliberately no log stream**, and the design's slot for one holds Alertmanager instead.
Jellyfin alone emits 2,644 priority-3 lines a day of ffmpeg chatter with no lever to stop it, so a
live tail is noise with a cursor on it. Alertmanager groups, suppresses repeats and reports
resolution - and had no interface at all before this, because its silence endpoint was declined a
public route. It still is: Caddy refuses anything that is not GET or HEAD on that path with a 405.

**`home-server-dashboard-build.timer` IS THE DEPLOY PATH, not just an updater.** This image's
content comes from the checkout rather than an upstream release, and `dist/` is not committed - so a
`git pull` touching `apps/dashboard/src/` deploys **nothing at all** until that timer runs, silently,
while every other change in the same commit takes effect on `daemon-reload`. Nightly rather than
weekly for that reason. `verify-host.sh` asserts it is armed.

**A GUARD THAT ADAPTS, VALIDATES AND DOES NOTHING.** The `home.{$DOMAIN}` block carries two
refusals - 403 on Prometheus' admin API, 405 on Alertmanager's write paths. Written the obvious way,
at the top level of the site block alongside the `handle` directives, **both were dead code**:
Caddy executes directives in *its* order, not source order, and `handle` sorts before `respond`, so
the first matching `handle` terminated the request and neither matcher ever ran. A GET of
`/api/prom/api/v1/admin/tsdb/snapshot` returned **200**. Two things follow, and both are the same
lesson this file keeps rediscovering:

- **The guards live inside their `handle_path` blocks**, where `respond` does sort before
  `reverse_proxy` - which is why the identical construction on `metrics.{$DOMAIN}` has always
  worked. And the matcher there is written against the **stripped** path (`/api/v1/admin/*`), because
  `handle_path` rewrites before the handlers inside it run.
- **`caddy validate` cannot see this class of mistake.** It adapted cleanly both ways. Only a
  request tells them apart, so test the refusals with `curl` after touching that block.

**An expired session is a 302, not a 401, and it is the thing most likely to make this look broken.**
`forward_auth` redirects to `auth.avanserv.com` and `fetch` follows redirects, so an XHR *resolves*
with `res.ok` true and an HTML sign-in page as its body; `JSON.parse` then throws somewhere
unrelated and every panel silently shows nothing. `src/api/http.ts` is the single place that detects
it - a cross-origin redirect, or a `text/html` content type - and it reloads the page, because a
passkey prompt cannot be completed inside an XHR. The reload is rate-limited to once per 30s so a
502 page from a restarting upstream cannot become an infinite refresh.

**A stale dashboard must read as stale, never as healthy**, which is the trap this whole repository
is written around. `src/stores/host.ts` tracks **three independent** freshness primitives, because
each fails in a way the others cannot see: `generated_at` read from the file (not from its
Prometheus mirror, so a dead collector and a dead battery stay distinguishable), the collector's
last success, and `up`. Past threshold the banner appears, panels dim rather than blanking, and the
verdict is `unknown` - **not folded into `fail`**, because "the battery says everything passed" and
"nobody has asked the battery" must not look alike. The same reason `mode.routes: false` is rendered
as "not measured" rather than omitted.

**THE NETWORK PAGE DRAWS WHAT IS MEASURED, WHICH IS NOT WHAT ANYONE WANTS IT TO DRAW.** The obvious
design animates an arrow from container A to container B. **That number does not exist here and
cannot be made to**: `nsenter -n` into a rootless netns is `EPERM` as `core`, and
`/proc/net/nf_conntrack` is root-only, so there is no conntrack view of a netavark bridge at all.

What IS available is a container's bytes on a **segment**, and cheaply, for the exact inverse of the
reason node-exporter's filesystem collector fails. That one cannot read `/proc/1/mountinfo` because
host PID 1 is real root; these are the other way round - rootless podman maps container uid 0 to
`core`, so `ptrace_may_access` passes and every container's `/proc/<pid>/net/dev` is an ordinary file
read from the host. Measured on all 24, not assumed.

So the drawing is **bipartite**: a rail is a segment, a box is a container, and the only line
carrying a rate is the **spoke** between them. Declared routes are a second visual language, shown on
hover, static. **Reachability is asserted by git; motion is asserted by measurement; neither may
borrow the other's credibility.**

**A TWO-MEMBER SEGMENT IS NOT AUTOMATICALLY AN EXACT EDGE**, which was the first rule written and the
first live run disproved it. Every bridge also carries a gateway to the outside. `net-dashboard`
mirrors - `caddy.tx ~ dashboard.rx` and back - so those two really are only talking to each other.
`net-solver` does not: `prowlarr.tx` is 352 KB against `flaresolverr.rx` of **36 MB**, because
FlareSolverr is headless Chrome fetching indexer pages and nearly all of it is internet egress. So
exactness is derived from the data rather than asserted from the topology - and **reconcile on rates,
never on the raw counters**, because containers have different start times and their totals cover
different windows.

**THE TUNNEL IS THE BIGGEST NUMBER ON THE HOST AND THE FIRST IMPLEMENTATION THREW IT AWAY.** gluetun's
`tun0` lives in the torrent pod's namespace carrying **223 MB in and 3.6 GB out** - every byte
qBittorrent and JOAL have moved. It matches no declared subnet because it has no on-link route at
all: gluetun steers traffic onto it with firewall marks and policy routing, so the main table's
default stays on `eth0`. A subnet join therefore drops it silently. It is classified on the kernel's
own `tun*`/`wg*` device naming - not a table of this stack's services - and
`home_server_container_network_unmapped_interfaces` counts anything else that fails to map, written
as an explicit 0 so it can be alerted on.

**Three more things about that collector, each verified rather than reasoned about:**

- **Interface names are not in declaration order.** caddy is `eth0=net-transcode`,
  `eth3=net-ingress`, `eth6=net-media`. Join on the subnet from `/proc/<pid>/net/route`, never on the
  index. And read it **little-endian**: `000A15AC` is `172.21.10.0`, and the obvious byte order
  matches nothing at all, which is silent rather than wrong.
- **The four torrent-pod containers share one netns**, so reading all four reports the same bytes
  four times. `podman ps` reports `Networks: []` for gluetun, qbittorrent and joal and
  `[net-download]` only for the infra container, so emitting only for a non-empty `Networks` list
  attributes the pod once - from podman's own answer rather than a rule in a script.
- **The pod's container is `torrent-infra` while `topology.ts` calls the node `torrent`**, and
  `home_server_container_info{pod}` is **empty for all 24 containers**, so that label cannot bridge
  it. The `unit` label can: `torrent-pod.service`. (Which also means `ServicesPage`'s
  `pod {{ row.pod }}` branch has always been dead code.)

**`apps/dashboard/src/paths.ts` is the second hand-maintained duplicate and the more dangerous one**,
because it cannot be derived in full: `sonarr -> torrent`, `prowlarr -> flaresolverr` and nine others
live in an application's own database, which is gitignored runtime state. So `bin/lint-repo.sh`
**validates** rather than diffs - both endpoints must exist and must **share a segment**, since every
bridge is `isolate=true` and an edge between two isolated bridges draws a route that cannot exist. It
proves a path is *possible*, never that it is *used*, and the module header says so. Proven by
adding `flaresolverr -> sonarr` and watching it fail.

**It could not live in `topology.ts`.** That leg derives segment names with
`re.findall(r'id:\s*"([^"]+)"', topo)` over the **whole file**, so any new object literal there
carrying an `id:` field is read as a tenth network and fails the lint - a booby trap rather than a
check.

**`via` is derived, not declared, because the intersection is often larger than one.** caddy and
sonarr share `net-arr` **and** `net-download`; caddy and jellyseerr share `net-arr` and `net-media`.
Which one podman's DNS resolves at connect time is observable nowhere, so a hand-written `via` would
be a claim nothing supports. Six of the 38 edges are ambiguous this way, and the drawing renders them
as ambiguous.

**Two terminals, not one.** `wan` is inbound and `internet` is outbound, and collapsing them into a
single node is a modelling bug rather than a simplification: `duckdns -> wan` and `wan -> caddy` then
join up, and a path walk cheerfully reports `duckdns -> wan -> caddy -> sonarr` - two real routes
spliced at a place no packet crosses. A terminal also absorbs, so no chain passes through one.

**Motion stops when the data is stale, and dimming alone would not be enough** - the eye reads
movement long before it reads opacity, so a dimmed animation still asserts liveness. Under
`prefers-reduced-motion` the flow is **replaced** by a static magnitude tick rather than paused:
`tokens.css` kills animations with `animation-duration: 0.001ms !important`, which would leave a dash
pattern frozen mid-cycle and indistinguishable from the dotted "not measured" style. That tick is
drawn in both modes anyway, because `fixtures/shoot.mjs` takes still PNGs and is the only visual
review this repo has - an animation-only encoding would be invisible to it.

**Animate by the dash period, never by `getTotalLength()`.** A long spoke and a short one at the same
rate would otherwise travel at visibly different apparent speeds, which is decoration pretending to
be data. For the same reason the graph's viewBox preserves its aspect where `MetricChart`'s does not:
a stretched viewBox advances `stroke-dashoffset` at different apparent speeds on horizontal and
vertical spokes, and `vector-effect` cannot rescue it.

**Tooltips are a component, not the `title` attribute**, because the one that matters most cannot be
an attribute: `MetricChart`'s crosshair already snapped to the nearest real sample and computed its
value, then rendered no readout of either - its own comment promises "the rule, the dot and the
readout all name the same instant" about a readout that did not exist. The component carries three
typed slots, and the third is the point: `caveat` is where "this number is not what it looks like"
goes, so a grey LED meaning *nobody is checking* and a spoke showing an endpoint's total rather than
an edge both say so on screen instead of only in a source file. Native `title` stays for truncation
recovery, where a styled box would be worse than the one the OS positions.

****`src/topology.ts` duplicates what `stacks/` already declares**, which is the shape this file calls
the most driftable thing it has a name for when it rejects split-horizon DNS. It is allowed to exist
only because `bin/lint-repo.sh` parses both and fails on any difference. Discovering it at run time
is not available - no container may run `podman network inspect` - and these files are the authority
anyway, so reading git is more honest than re-deriving it.

**No chart library, and the reason is the gap.** The design is hand-drawn SVG throughout, so
matching it exactly costs less than bending a library into it. What that arithmetic has to get right
is that a Prometheus range query returns *nothing* for a timestamp where the series did not exist,
and `polyline` cannot express a break - it would draw a straight line across an outage, which reads
as "steady" when it means "absent". Lines are built as a `path` with a fresh `M` after every gap.

**Fonts are vendored, not fetched.** `@fontsource/*` self-hosts Geist and Azeret Mono in the bundle,
for the reason `apps/jellyfin/custom.css` records at length about the sixteen `@import` URLs it used
to carry.

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
systemctl --user start home-server-dashboard-build.service   # THE DEPLOY for apps/dashboard/
systemctl --user restart dashboard            # then swap onto the new bundle
podman exec caddy caddy reload --config /etc/caddy/Caddyfile   # routing change, no downtime

./bin/verify-host.sh                          # the whole battery; also writes the MOTD
./bin/verify-host.sh --routes                 # plus the public routes (slow)
./bin/verify-host.sh --json | jq .summary     # the same findings, machine-readable
jq -r '.checks[]|select(.status!="pass")|"\(.status)  \(.id)  \(.message)"' \
  /var/lib/home-server/status.json            # what the hourly run last found
bin/collect-metrics.py --print | grep container_network   # the per-segment counters
./bin/verify-media.sh "/mnt/media/library/transcoded/movies/<film>/<film>.mkv"
./bin/verify-media.sh --library movies        # will these drift in a browser?
podman auto-update --dry-run                  # 17 rows with a policy, not an empty table
systemctl --user list-timers                  # verify hourly, backup + auto-update + search nightly

systemctl --user start home-server-backup     # back up now rather than waiting for 03:00
journalctl --user -u home-server-backup -n 50

./bin/search-missing.py --dry-run --verbose   # what is missing, and what is merely unreleased
systemctl --user start home-server-search.service   # sweep now rather than waiting for 04:30
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
| `net-metrics` | caddy, prometheus, node-exporter, alertmanager, ntfy-alertmanager, ntfy |
| `net-dashboard` | caddy, dashboard |

Each has its own `NET_SUBNET_*` variable. **Caddy joins every segment individually** - a shared
"proxy" network holding everything with a UI would re-flatten the topology and buy nothing. It is
deliberately absent from `net-solver` and from `net-egress`.

**`net-dashboard` holds two containers and exists so that it can hold two.** The obvious home for
the dashboard was `net-metrics`, since Prometheus is what it reads, and that is the wrong answer:
membership there would let it open a connection to `prometheus:9090` **directly**, behind the
`/api/v1/admin/*` refusal the Caddyfile puts at every public entrance - and Prometheus runs with
`--web.enable-admin-api`, which carries `delete_series`. So the dashboard queries Prometheus the
same way the browser does, through Caddy, past the guard. It holds no credential, makes no outbound
request, and serves a static bundle plus one read-only JSON, which is what makes a segment of its
own cheap rather than fussy.

**`net-metrics` is the one segment that could re-create that mistake, and the design inverts it to
avoid doing so.** The obvious metrics topology puts an exporter for each application on both
`net-metrics` and that application's own segment - which leaves `net-metrics` adjoining `net-arr`,
`net-download`, `net-media` and `net-transcode` at once, i.e. exactly the shared proxy network the
paragraph above rejects, wearing a different name. **Prometheus multi-homes instead; exporters never
do.** It joins those segments as a pure *client*, with its listener pinned to its `net-metrics`
address, so nothing on `net-arr` can open a connection to it - one container to harden rather than
eight, and no exporter holds a credential outside the segment that already holds it.

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
| `minFormatScore` | 30 | The floor. **It was unreachable until 2026-08-19**, and this table said otherwise. |
| `Lang: Original` | **30**, was 10 | The correction. The whole scale is Surround 10, x264 10, x265 20, AV1 30, Original 30 - so at 10 a VO-only release scored 20 against a floor of 30 and **Silent Hill: Revelation 3D returned 124 releases and approved zero**. At 30 an identifiable-VO release clears the bar alone; one with no language information (score 0) still does not. |
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

## The seeding policy, and the one part qBittorrent cannot express

**Seed for at least 72 hours, then stop at ratio 1.5 or one week, whichever comes first.** Since
2026-08-18 that is enforced by `bin/apply-seeding-policy.py` on `home-server-seeding.timer`, hourly.

**Deletion is still Radarr's and Sonarr's**, and the script deletes nothing. Both run with
`removeCompletedDownloads`, which removes the torrent *and its files* once the client reports it
done seeding - so the whole policy is expressed by deciding when a torrent is allowed to **stop**.
That split keeps deletion with the two applications that know whether a file was ever imported.

**They still track torrents imported months ago**, which is easy to conclude the opposite of. Radarr's
queue endpoint lists only what is downloading or awaiting import, so a seeding torrent looks
forgotten - but `/api/v3/history?downloadId=<hash>` still holds `grabbed` and `downloadFolderImported`
for a film grabbed in November 2025, and it was duly reaped. **Check history, not the queue.**

**The floor is the half that needs code, because every share limit qBittorrent has is a MAXIMUM.**
There is no minimum-seed-time setting anywhere in it, so a floor can only be enforced by withholding
the limits until a torrent has earned them. It binds in exactly one case - a torrent reaching ratio
1.5 in under three days - since the seven-day limit can never fire before 72 hours.

**THE GLOBAL LIMITS MUST STAY OFF, and that is the load-bearing part.** A per-torrent limit of `-2`
means "use the global one", and a new torrent starts at `-2` - so a global ratio limit reaps it hours
into its life with the script none the wiser and the floor silently gone. The script re-asserts
`max_ratio_enabled=false` every run rather than trusting the UI, and pins held torrents to an
explicit `-1` rather than leaving them at `-2`, which is only as safe as the setting it defers to.
`seeding.timer_enabled` and `seeding.run_age` are what prove the script is still running.

**`shareLimitAction` IS A STRING THAT SILENTLY ACCEPTS THE INTEGER.** qBittorrent 5 made it a
required parameter of `setShareLimits`, and `shareLimitAction=0` and `=3` **both answer 200 and both
store `Default`** - so the spelling matching qBittorrent's own enum is accepted, ignored, and
indistinguishable from success. Only `Stop` stores `Stop`. The only way to tell is to write the value
and read `share_limit_action` back out of `torrents/info`; the status code cannot. It is set to
`Stop` rather than `Default` for the same reason the limits are `-1` rather than `-2`: `Default`
defers to the global action, and a global `RemoveWithContent` would have qBittorrent delete files
behind Radarr.

**It fails in the safe direction.** A stopped timer means no torrent is ever promoted past the floor,
so nothing stops and nothing is deleted - the disk grows rather than the tracker account being spent.
Every check in the `Seeding policy` section is therefore WARN or PASS, never FAIL, for the reason the
Logs and Metrics sections give.

**Applying it reclaimed 214 GB on the first run** (`downloads/` 445 -> 231 GB, the volume 14% -> 11%),
because eight torrents had been seeding 13-39 days at **ratio 0** - the Harry Potter and Hobbit films
whose data had been rewritten in place, so they could never reach a limit and could never be cleaned
up. That is the space cost of the `mkvpropedit` damage, and it had no expiry.

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

`watch`, `request` and `ntfy` are the only routes not behind sign-on: each authenticates its own
users, and their clients have no browser in which to complete a passkey prompt. **`ntfy` is the one
that looks wrong and is not** - an alerting endpoint outside sign-on invites the obvious objection,
but the client is a phone app in exactly the position a TV is, and `auth-default-access: deny-all`
means the hostname on its own reaches nothing. Alertmanager and the bridge get **no** public route;
the bridge's Silence button would require one, and that trade was declined. See "Alerting".

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

**The sixty-four conclusions from auditing the running host live in `docs/known-state.md`.** They
moved out of this file on 2026-08-19, when it passed the character budget that decides what is
loaded into context at all - so the choice was not which paragraphs to keep, it was whether the file
carrying them stayed loadable. Nothing was rewritten or dropped; the section was lifted whole.

**The index below is the half that has to stay here**, because knowing a landmine exists is what
sends you to read it, and an entry nobody knows about is one nobody reads. **Read the full entry
before changing anything in the area it names** - most of them record a failure where every visible
signal read green.

**Append to `docs/known-state.md` AND add the matching line here. Both halves or neither.**

### The rename, and the three things that did not follow
- Moving the checkout dangles the `greenboot/required.d` symlink, which is a red boot, and leaves
  renamed units in runtime state as `failed` phantoms only `reset-failed` clears.
- The project was `media-stack` until 2026-08-15. Three `git grep` hits are deliberate, and the
  restic identity was rewritten in place rather than edited.

### Podman is not Docker
- `firewalld` now governs published ports - closed by default, symptom `No route to host` against a
  container that looks perfectly healthy.
- SELinux blocks `/dev/net/tun` until `container_use_devices` is on, with **no AVC logged**.
- Podman does not create missing bind-mount source directories, and `Restart=always` makes that a
  silent 5-second retry loop rather than a failure.
- Podman will not guess a registry: every image reference must be fully qualified.
- Every quadlet interpolating a variable needs its own `EnvironmentFile=`, `.network` units included.
- `/mnt` is a symlink to `/var/mnt`, so the unit is `var-mnt-media.mount` with `Where=/var/mnt/media`.
- Quadlet's `Environment=` splits on whitespace and truncates silently. Quote any value with a space.

### Reaching a service, and restoring one
- A 302 from an admin route proves the proxy and sign-on, not the backend.
- A config restored from a running stack can carry live lock files; qBittorrent then exits one
  second after starting, logging only `termination initiated`.
- `WebUI\LocalHostAuth` must be `false`, or gluetun's port-forward push gets a 403 for ever.

### The host: image, driver, and which updater is armed
- uCore `stable-nvidia-lts`, immutable: host tools go in `~/.local/bin`, host config in
  `host/butane/ucore.bu`, and Ignition runs once so editing it changes nothing running.
- `-lts` is the NVIDIA **driver** branch, not an LTS kernel. Reverting the tag reinstalls 610.
- Zincati and `bootc-fetch-apply-updates.timer` are **masked**, not disabled - exactly one updater
  may be armed, and `disable` is silently undone by a `Wants=` elsewhere.
- `AutomaticUpdatePolicy=stage` is uCore's own default, restated in `ucore.bu` deliberately.
- The image ref is `ostree-image-signed:docker://`. Do not ship your own policy or key through
  Ignition - it becomes a permanent `/etc` override that survives a key rotation.

### Container auto-update, and the rollback it rests on
- Images follow tags, nightly. `Notify=healthy` is what makes the rollback fire, and a `.build` unit
  needs its own timer because auto-update does not trigger one.
- **A rollback restores the image and cannot un-migrate a database.** The 9.5-hour Pocket ID outage,
  and why a health probe shelling out to `curl` is an undeclared dependency on a binary the image
  merely happens to ship. Ten other quadlets still probe that way.
- The nightly prune does not eat the rollback - but **never run `prune -a`**.
- That same prune fails the unit over a leftover buildah working container, and the failure names the
  one component that was working.
- uCore ships its own `nvidia-cdi-refresh`; a second CDI spec is rejected rather than merged.

### `/boot` holds two slots and cannot be grown
- One slot per distinct kernel+initramfs, 303 MB of 350 used, and XFS cannot be shrunk. Five
  corrections learned by doing it wrong: pinning the booted index rather than 0, unpinning after
  verifying, WARN vs FAIL under `--greenboot`, `cleanup -r` taking two deployments, and the pending
  deployment it cannot reclaim at all.

### The nightly OS updater can silently skip a real update
- `rpm-ostree upgrade --check` can be wrong and `rpm-ostreed-automatic` believes it, so the host
  stops taking OS security updates indefinitely while every signal reads green.

### Checks that could not see the thing they measured
- A check that counts the unit executing it blocks the remedy for its own condition.
- `update.policy_count` spent three minutes a run asking every registry a local question - and read
  `$repo` several hundred lines before it was assigned, reporting "not measured".
- **Caddy was down for 35 minutes and three checks looked straight at it**: a dependency failure is
  `inactive`, not `failed`, and a container that never started is absent rather than unhealthy.
- `routes.ntfy` asked for `/`, ntfy's public web UI, so it was wrong in both directions at once.

### Two defects in one uCore image
- `policy.json` shipped truncated with NUL padding: nothing could be pulled or built, 22 running
  containers stayed healthy throughout, and **`jq` accepts the broken file**. The repair is a local
  `/etc` override that `deploy.image_policy` carries the removal trigger for.
- Performance Co-Pilot shipped unlabelled binaries and blocked an OS update. Its timers report
  `disabled` from `list-unit-files` and were active - check `list-timers`.

### greenboot, GRUB, and the red boot that arms the fallback
- **A red boot arms GRUB itself and stays armed until a green boot**, silently turning the next
  deliberate reboot into a rollback while every signal reads correct. Four things went wrong at once,
  including six sites selecting on `.staged` when `pending` is the state that boots next.
- `greenboot.verdict` FAILed for ever over an event nobody could act on. The `red.d` hook assertion
  is what makes the downgrade to WARN sound rather than a silencer.

### A digest that is not comparable, and a marker a reboot wipes
- Two kinds of sha256 name the same image, so the obvious digest check fires on every host, on every
  run, on a perfectly current machine. Resolve the index to this host's architecture first.
- `ExecMainExitTimestamp` is runtime state a reboot wipes, so "has never run" and "has not run since
  boot" look identical.

### Disks, and where things must not be put
- `/mnt/media` has no redundancy, holds only re-downloadable media, and is deliberately not backed up.
- Transcode scratch stays off the media disk - do not "simplify" it back under the media volume.
- `nv-patch.sh` is deleted and should not come back.
- `config/` is on `nvme0n1p4`, not `p3`. `p3` is the 350 MB `/boot`.

### The segmentation, and what it buys
- The forbidden edges are verified **by IP from a throwaway container**, never by name resolution.
- Prowlarr is the single hop out of `net-solver`, so its own login matters more than the others'.
- SMT is on deliberately, which removes FCOS's `nosmt`; `net-solver` isolation is the barrier that
  is trusted instead, and the `kernel_arguments` block is what to revert if that stops looking right.
- Gluetun's HTTP and Shadowsocks proxies are off - unauthenticated, they were an open proxy into
  the VPN for any LAN device.
- Services address each other over their shared network, never a public hostname.
- Tinyauth's token and userinfo URLs are internal; only the two the browser follows stay public.

### Logs, and why priority is not a signal
- A container's stdout is journal priority 6 and its stderr is priority 3, so an application logging
  to stderr records every cheerful 200 as a journal **error**.
- `journalctl -p err` is still not usable: Jellyfin alone emits 2,644 priority-3 lines a day of
  ffmpeg chatter and cannot be told otherwise. Alerting keys on unit state and container health.
- podman's `health_status` events were 47.3% of all journal bytes and are now off entirely.

### The media spindle, measured
- It gets **slower** with concurrency - two readers cost 45% of total throughput and the penalty is
  head travel, not layout. The answer to "it's slow" is fewer jobs, never more bandwidth.
- Tdarr's spindle reads are a burst at job ingest; it then works entirely from the NVMe cache.

### Jellyfin and the transcode pipeline
- Jellyfin is the largest CPU consumer and is not serving anybody: **trickplay has its own hardware
  switches**, independent of playback's, and all three shipped off.
- Playback hardware decoding was **never** off - a line-matching grep cannot show an XML element's
  contents, which is how that was misdiagnosed.
- An irregular keyframe interval breaks browser playback, and the symptom names neither cause.
  Throttling is innocent, and `bin/verify-media.sh` is the check.
- Jellyfin sitting **at** its `MemoryHigh` with a climbing throttle counter is fine. Read `anon` vs
  `inactive_file` and `memory.pressure`, not `memory.events high`.
- Jellyfin 10.11's own queries are slow; inherent to the EF Core rewrite, not a configuration problem.
- Two NVENC sessions already pin the encoder block at 100%, which is why the worker limits are
  `transcodegpu:2, transcodecpu:0`.
- `queueSortType: sortPathAZ` is how episodes come out in order.
- The community "5 steps" flow was actively destructive and is retained only as a rollback.
- A Tdarr health check is a full-file decode; queueing 470 wedged the whole host while it still
  answered ICMP and completed TCP handshakes.

### cgroup limits, and the controller that was not delegated
- `io` is **not** delegated to the user manager by default, so every `IOWeight=` in `stacks/` was
  inert - the control aimed at the cause above was the one not working. Verify; the failure is silence.
- Every service quadlet carries `MemoryHigh`/`MemoryMax`; the Tdarr units add CPU and IO weights.
  These are systemd cgroup directives, not podman flags.
- Tdarr runs again, both units. **A `Wants=` on a disabled unit silently re-enables it** - use
  `After=` for ordering, never `Wants=`.

### Indexers, and three ways to find nothing while everything is green
- **Adding indexers was the wrong answer and was measured rather than argued.** Most of what is
  "missing" is not released yet, and `isAvailable` reads true for a 2027 film - it means "may Radarr
  grab this", not "does this exist".
- **The `[VO]` floor was unreachable and this file asserted the opposite.** 124 releases, 0 approved,
  and the "scores ~50" claim above was wrong for as long as the profile existed.
- **A back-catalogue title is searched once, at add time, and never again.** RSS only carries new
  uploads, so 94 episodes stayed missing while three approved releases sat on a configured indexer.
  `bin/search-missing.py` is the fix, and it searches by season rather than by episode.
- **A stalled download blocks every alternative release and reports itself as `downloading`.** One
  refused all 49 candidates for a film with `already meets cutoff`, six of them at score 870.
- The ISP resolver returns a blocking page for several indexer domains, which is why prowlarr and
  flaresolverr carry their own `DNS=`.
- **That override works and is no longer the explanation for a down indexer.** Six zeros were five
  unrelated causes, none of them DNS.
- Prowlarr pushes every indexer to every application and retries the refused ones for ever. Some gap
  between the three counts is correct, so read them - do not alert on equality.

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

   **The time-series layer is done too, 2026-08-15** - Prometheus, node-exporter and
   `bin/collect-metrics.py`, at `metrics.avanserv.com`. See "Metrics". That closes the other half of
   what a dashboard needs: `status.json` says what is true now, and the store says when it stopped
   being true. **Everything that list named as "still to come" landed the same day**: GPU, sensors
   and SMART, the application sources over `podman exec`, all 64 checks as `home_server_check_status`
   series, and the TSDB snapshot in both backup scripts. **cAdvisor is the one item that was dropped
   rather than done** - the collector has to read the same cgroup files anyway for the four numbers
   cAdvisor does not export, so a second container would have been a second source for one truth.
   The steady-state cardinality is 2,896 series against the 4,000 the check budgets for.

   **The notification path is done too, 2026-08-15**, which closes this item. Prometheus rules ->
   Alertmanager -> ntfy-alertmanager -> ntfy -> phone, 17 rules in five groups, at
   `ntfy.avanserv.com`. See "Alerting". Prometheus having alerting rules built in is part of why it
   was chosen over a store needing a second container for them, and that paid off exactly as
   expected.

   **The dashboard is done too, 2026-08-15, and this item is now closed.** A Vue 3 application at
   `home.avanserv.com`, in `apps/dashboard/`, built on the server from the checkout. It is what
   every keyed id and every series was for. See "The dashboard".

   **All five pages are built as of 2026-08-18.** Network was the last, and it is the only one that
   needed a new measurement rather than a new arrangement of existing ones - see "The dashboard".

   **All four pages were built as of 2026-08-17.** Home and Library needed Jellyfin sessions,
   Jellyseerr requests, poster images and the \*arr queues, none of which was collected - so they
   are a collector change first and two pages second. **It is read-only, structurally**: no container
   can reach the podman socket, so restart and pull would need a privileged host-side surface
   reachable from a browser - the next deliberate decision here, not an oversight in this one. Every
   action chip is a deep link into the owning application instead.

   **Do NOT build either on `journalctl -p err`.** Jellyfin alone emits 2,644 priority-3 lines a day
   of ffmpeg chatter and there is no lever to stop it - see Known state. Unit state and container
   health are the signal. Note also that `duckdns` and `unpackerr` never report health - neither
   serves HTTP - so a check assuming every container has a health status reports them broken for
   ever. `home_server_container_health` is **absent** for those two rather than zero, which is what
   lets the `ContainerUnhealthy` rule cover every container without naming any.

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
