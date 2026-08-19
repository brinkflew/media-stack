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
| `docs/` | what was learned the hard way, and most of what this file used to carry. See the index below. |

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

## Where the rest of this lives

**This file used to carry all of it, and stopped being loadable.** It reached 133 KB - about 33,000
tokens read in full before any work begins, whether the session is about a Caddy route or the
transcode policy. The known-state section was lifted out on 2026-08-19 for that reason and the rest
followed the same day, by the same rule: **lifted whole, never rewritten.** The arguments in them
are load-bearing and several were paid for in outages.

| File | What it carries |
|---|---|
| `docs/networking.md` | one network per trust boundary, `isolate=true`, the torrent pod, the media mount, ingress and passkey sign-on |
| `docs/media-pipeline.md` | `queued/` -> `transcoded/`, Tdarr's libraries and flow traps, the transcode policy, the Radarr `[VO]` profile, hardlinks, the seeding policy |
| `docs/observability.md` | `status.json` and its stable check ids, Prometheus and the collector, the alert chain to the phone |
| `docs/backups.md` | the three copies, the append-only off-site key, and why a backup is not proven until restored |
| `docs/dashboard.md` | the Vue application, its five sources, and what it may and may not assert |
| `docs/repo-conventions.md` | `config/` vs `apps/`, how a file reaches a container, ASCII, `bin/lint-repo.sh` |
| `docs/known-state.md` | the seventy-four conclusions from auditing the running host |

**What stays here is what has to be known BEFORE touching anything**: what this is, how a change
reaches the server, secrets, the commands, and the known-state index below. Everything else is one
`Read` away, and the index is what tells you to go and read it.

**A new section belongs in one of those files, not here.** Adding it here is how this file grew back
past the point that forced the split.

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

## Known state

**The seventy-four conclusions from auditing the running host live in `docs/known-state.md`.** They
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
- `WebUI\LocalHostAuth` must be `false`, or gluetun's port-forward push gets a 403 for ever - and
  **JOAL shares that namespace**, so it reaches qBittorrent's WebUI unauthenticated. Not cheaply
  fixable; what would close it is dropping JOAL.

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
  merely happens to ship. **Eighteen of the twenty-three quadlets still probe that way, and NONE of
  those eighteen images declares a healthcheck of its own** - so Pocket ID's fix cannot be copied
  across, and `containers.probe_binaries` watches the dependency instead. This line said "ten" until
  2026-08-19, when it was counted.
- **The rollback now has a restore point in front of it.** `bin/pre-update-snapshot.sh` runs as
  `ExecStartPre=` on `podman-auto-update.service`, because the updater fires at ~00:00 and the
  backup at 03:00 - so the newest snapshot was 21 hours old at exactly the moment one was needed.
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
- **`ContainerRestartLoop` read a counter that resets on every restart**, so it could never fire -
  0 through all 6,224 of Pocket ID's restarts. Systemd's `NRestarts` is the one that survives.
- **`Restart=always` at `RestartSec=5` cannot reach systemd's 5-in-10s limit**, so no unit here ever
  gave up. Detection was never the problem; an end state was.
- **Alertmanager was a destination and never a scrape target**, so three of the four hops to the
  phone were unmeasured - including the 401 its own config file warns about.
- **The one job that proves the backups restore was the one job with no record**, and running it
  found the workstation's third copy four days stale.
- **A Postgres dump outlives its own accuracy**, because the shadow tree is never deleted and the
  `protect` filter keeps last night's copy - so existence and freshness are asserted by different
  scripts on different machines.
- **A `Slice=` naming a slice with no unit file silently gets systemd's defaults**, so the fleet's
  one aggregate ceiling can be absent while every member is healthy and fully observed. The
  `host/systemd/` symlink loop globs by EXTENSION, which is where that comes from.
- **The collector's cgroup join was flat**, so the first unit ever placed in a slice would have lost
  32 of its 43 series with nothing but a counter to say so. Not `/proc/<pid>/cgroup` - the pod
  members resolve somewhere else entirely.

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
  `bin/search-missing.py` is the fix.
- **Searching by season was the obvious economy and returned nothing**, because a season query asks
  for a season PACK. Disproved by the first live run; the cap is counted in episodes now.
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
   keyed by a stable id, plus a `facts` object of the numbers, rewritten hourly - see `docs/observability.md`. The journal is declared and bounded at 90 days, and 47% of its volume (podman's
   `health_status` events) is gone. **The durable-record gap named below is closed**: `status.json`
   carries `generated_at` and lives where a reboot does not reach, so this script finally has the
   marker every other job already had.

   **The time-series layer is done too, 2026-08-15** - Prometheus, node-exporter and
   `bin/collect-metrics.py`, at `metrics.avanserv.com`. See `docs/observability.md`. That closes the other half of
   what a dashboard needs: `status.json` says what is true now, and the store says when it stopped
   being true. **Everything that list named as "still to come" landed the same day**: GPU, sensors
   and SMART, the application sources over `podman exec`, all 92 checks as `home_server_check_status`
   series, and the TSDB snapshot in both backup scripts. **cAdvisor is the one item that was dropped
   rather than done** - the collector has to read the same cgroup files anyway for the four numbers
   cAdvisor does not export, so a second container would have been a second source for one truth.
   The steady-state cardinality is 2,896 series against the 4,000 the check budgets for.

   **The notification path is done too, 2026-08-15**, which closes this item. Prometheus rules ->
   Alertmanager -> ntfy-alertmanager -> ntfy -> phone, 17 rules in five groups, at
   `ntfy.avanserv.com`. See `docs/observability.md`. Prometheus having alerting rules built in is part of why it
   was chosen over a store needing a second container for them, and that paid off exactly as
   expected.

   **The dashboard is done too, 2026-08-15, and this item is now closed.** A Vue 3 application at
   `home.avanserv.com`, in `apps/dashboard/`, built on the server from the checkout. It is what
   every keyed id and every series was for. See `docs/dashboard.md`.

   **All five pages are built as of 2026-08-18.** Network was the last, and it is the only one that
   needed a new measurement rather than a new arrangement of existing ones - see `docs/dashboard.md`.

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
