# Backups

Lifted whole from `CLAUDE.md` on 2026-08-19. Nothing here was rewritten.

`config/` is the only part of this system that cannot be rebuilt from git, which is what every
argument below is about. Read the whole of a section before changing anything it describes.

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

**None of that was recorded anywhere until 2026-08-19, which made it unfalsifiable.** Every other leg
here writes a marker into `~/.cache/home-server/backup-state` and `bin/verify-host.sh` grades it for
staleness. `bin/verify-restore.sh` wrote nothing at all - so "this ran last night" and "nobody has
run it since March" were the same observable state, on the one job whose entire purpose is to turn an
assumption into a measurement. It now writes `restore_verified_local_at` or
`restore_verified_offsite_at` over SSH, exactly as `bin/backup-offsite.sh` already does for
`offsite_pruned_at`, and **only on success** - a failed verification leaves the previous timestamp to
go stale rather than recording a run that proved nothing.

**Two keys and two ceilings, 30 days and 90.** The local repository sits on the same disk as
`config/`, so proving it restores says nothing about surviving that disk; a single shared marker
would let a cheap monthly local run stand in for an off-site copy nobody had ever tested. The
off-site ceiling is the **longer** of the two only because that verification pulls data back across
the network and costs egress - it is the more important of the pair, not the less. `RestoreNeverProven`
alerts on either, and keys on the **check** rather than on the marker's age, because a staleness rule
needs the series to exist and the state it has to cover is a marker that was never written.

**`--repo local` means the WORKSTATION's copy, and running it for the first time found that copy four
days stale.** There are three repositories, not two: the server's nightly one at
`/var/backups/home-server`, the off-site, and the third copy at `~/backups/home-server` that
`bin/backup-config.sh` writes **by hand from the workstation**. That third copy's newest snapshot was
2026-08-15, taken before ntfy existed, so the verification failed on a missing `ntfy/auth.db` - the
alerting accounts, whose loss is invisible until a phone quietly stops authenticating. Nothing tracks
its freshness: `offsite_pruned_at` records the workstation's *prune*, and there is no marker for the
copy itself. That gap is named here rather than closed.
