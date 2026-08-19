# Known state

Conclusions from auditing the running host. **Do not rediscover these.**

`CLAUDE.md` carries a one-line index of every entry below, under its own `Known state` section.
That index is what is always in context; this file is the detail behind each line, and the reason
each conclusion is held. Read the entry before changing anything in the area it names - most of
them record a failure where every visible signal read green.

**Append here rather than in `CLAUDE.md`, and add the matching index line when you do.** An entry
nothing points at is one nobody reads.

## The rename, and the three things that did not follow

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

## Podman is not Docker

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

## Reaching a service, and restoring one

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

## The host: image, driver, and which updater is armed

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

## Container auto-update, and the rollback it rests on

- **Images follow tags and `podman-auto-update` runs nightly** (since 2026-08-13). Digest pinning was
  dropped because nothing maintained it - thirteen of eighteen images were three months old. See
  `stacks/README.md` for the tag choices, which are the remaining risk control. Two things about it
  are load-bearing and non-obvious:
  - **`Notify=healthy` is what makes the rollback fire.** auto-update restores the previous image
    only if the unit fails to **start**, and systemd otherwise calls a container started the moment
    it runs - so a broken-but-running image passes and nothing is restored. Proven by pointing a
    test unit at a deliberately broken image and watching the journal restore the old one.
    **What it cannot protect is anything that migrates its datastore on start** - see the entry
    two below, where this bullet is the direct cause of the longest outage recorded here.
  - **auto-update does not trigger a `.build` unit.** Caddy is `AutoUpdate=local`, which notices a
    new image without producing one, and a `.build` unit only runs when its image is absent - so
    without `home-server-caddy-build.timer` Caddy alone would never update. That unit also needs
    `Pull=newer` in `caddy.build`, because podman build's default pull policy is `missing` and it
    would otherwise reuse a stale local `caddy:2` for ever while succeeding in four seconds.
- **A ROLLBACK RESTORES THE IMAGE AND CANNOT RESTORE THE DATA, so `Notify=healthy` protects nothing
  that migrates its datastore on start.** That bullet is the safety net this whole tag-following
  design rests on, and on **2026-08-19** it was the direct cause of a nine-and-a-half-hour outage of
  the service gating **every** sign-on here. The sequence is worth having in full, because every
  step in it is individually correct:
  - **00:14:50** auto-update pulls Pocket ID **2.14.0**. It starts, **migrates its SQLite schema** to
    `20260814120000`, logs `Server listening`, registers its cron jobs and completes a SCIM sync -
    i.e. it is up and serving.
  - **The startup probe never passes.** 2.14.0 **removed curl from its Dockerfile** (*"remove
    unnecessary curl dependency from Dockerfile"*, commit `987d1a8`) and the quadlet probed with
    `curl -fsS http://localhost:1411/healthz`, so it exited **127**. Sixty retries at 5s expire,
    `Notify=healthy` never fires, systemd kills the unit at **5min 12.9s** -
    `Failed with result 'protocol'`.
  - **00:20:03** auto-update does exactly what it is designed to do and re-tags **2.13.0** onto `:v2`.
  - **00:20:04 onwards** 2.13.0 refuses the migrated database - *"database version (20260814120000)
    is newer than application version (20260802120000), downgrades are not allowed"* - and exits 1
    every five seconds. Restart counter **6108** by the time it was found, in a browser, as a 502.

  Four things follow, and the first is the general one:

  - **The rollback is a safety net for STATELESS upgrades only.** Restoring an image cannot
    un-migrate a database, so for anything with forward-only migrations a rollback converts a failed
    start into a **permanent** deadlock that no restart clears. Pocket ID, the \*arr apps, Jellyfin
    and Tdarr all migrate on start. Nothing here detects it and nothing can undo it: the remedy is
    always to go *forward* to the version matching the schema, never back.
  - **`ALLOW_DOWNGRADE=true`, which the error message itself suggests, is the WRONG lever.** It does
    not restore the old version's compatibility - it lets that version destructively rewrite the
    schema.
  - **A HEALTH PROBE THAT SHELLS OUT TO `curl` IS AN UNDECLARED DEPENDENCY ON A BINARY THE IMAGE
    MERELY HAPPENS TO SHIP**, and its absence is indistinguishable from the application being down.
    This is the **second** time an image dropped curl here - `bin/collect-metrics.py`'s `api_get`
    already falls back to wget because gluetun and jellyseerr ship only that. **Prefer the image's
    own declared `HEALTHCHECK`**, which `skopeo inspect --config` reads without pulling. Pocket ID
    has shipped `CMD ["/app/pocket-id", "healthcheck"]` all along and the quadlet was overriding it
    with something strictly worse; `gluetun.container` already had the right shape. **Ten other
    quadlets still probe with `curl` and eight with `wget`.**
  - **Detection worked, and is not what failed.** `containers.units_active` - added the day before,
    for the Caddy outage below - reported `quadlet service(s) NOT running: pocket-id.service`
    `(activating)`, and `CheckFailing` went **critical in Alertmanager at 00:55:02Z** and stayed
    there. The gap was between the notification and anyone acting on it, which is a different
    problem from the ones this file usually records.
- **The nightly prune does not eat the rollback.** The shipped `podman-auto-update.service` runs
  `podman image prune -f` afterwards, but a superseded image keeps its repository digest and is
  therefore not *dangling* - verified: every pre-update image survived. Only `prune -a` would remove
  them, so **never run that**; the previous image in local storage is the only rollback there is.
- **THAT SAME PRUNE FAILS THE UNIT, AND THE FAILURE NAMES THE ONE COMPONENT THAT WAS WORKING.**
  A `.build` unit interrupted mid-run leaves a **buildah working container** in storage. It holds
  the build-cache layer it was made from, so that image is both dangling *and* in use, and
  `podman image prune -f` exits **125** on it rather than skipping it. podman ships that prune as
  `ExecStartPost=` on `podman-auto-update.service`, and an `ExecStartPost` failure fails the unit -
  so on 2026-08-17 and 2026-08-18 `podman auto-update` exited **0**, all eighteen containers
  updated correctly, and systemd reported the updater broken:

  ```
  Main PID: ... (code=exited, status=0/SUCCESS)          <- the update
  Control process exited, code=exited, status=125/n/a    <- the prune
  Error: image used by 06fc6c080d43...: image is in use by a container
  ```

  Seven had accumulated across two occasions, four of them stamped inside the reboot transition of
  the 2026-08-16 unattended window. They held 2.1 GB of dangling images and blocked **12.1 GB** of
  reclaim, and nothing measured any of it - the only visible signal was `containers.failed_units`
  naming `podman-auto-update.service`, three scripts from the cause and pointing at the wrong
  component. Two changes, and **neither works without the other**:
  `host/systemd/podman-auto-update.service.d/` makes the prune non-fatal, because housekeeping that
  can be skipped for a night must not overrule the update `Notify=healthy` protects; and
  `containers.storage_orphans` WARNs on the leftovers directly, which is what makes the first a
  correction rather than a silencer. **`ExecStartPost=` must be cleared with an empty assignment
  before the `-` form is added** - it is a list directive, so a drop-in that only adds appends, and
  the original fatal line still runs first. Clear them with `podman rm --storage <name>`; **buildah
  is absent on uCore**, so `buildah rm` is not the tool. Note this does not reopen the bullet above:
  it is still `prune -f`, never `prune -a`.
- **uCore ships NVIDIA's own `nvidia-cdi-refresh.{path,service}`**, writing `/run/cdi/nvidia.yaml` on
  tmpfs, with the `.path` unit watching `modules.dep` and `nvidia-ctk` so a driver change regenerates
  the spec with no reboot. `ucore.bu` used to define a second unit writing `/etc/cdi/nvidia.yaml`.
  The files were byte-identical, which is exactly why it was invisible - but a spec names the driver
  version in dozens of paths, so the first driver-changing update would have left two files defining
  `nvidia.com/gpu=1` with different library paths, which the resolver **rejects rather than merges**.
  Both Jellyfin and tdarr-node-01 consume that device. Removed 2026-08-13; `bin/verify-host.sh`
  asserts exactly one spec exists and that it names the running driver.

## `/boot` holds two slots and cannot be grown

- **`/boot` costs one slot per distinct KERNEL+INITRAMFS, not per deployment**, holds exactly two
  (2 x 146 MB + 11 MB GRUB = 303 MB of 350 MB), and **cannot be grown** - `nvme0n1p4` is XFS, which
  cannot be shrunk by any tool, so enlarging it means repartitioning the disk that carries `config/`.
  Five corrections learned by doing it wrong, on 2026-08-14 and again on 2026-08-16:
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
  - **UNDER `--greenboot` IT IS A WARN WHATEVER THE CAUSE, pinned or not, and that was learned the
    expensive way.** The bullet above narrowed the FAIL to "low `/boot` with nothing pinned" and
    stopped there, which left the general case wrong: **a rollback cannot fix a full `/boot`, it
    makes it worse**, because the deployment being rolled back to needs a slot of its own. On
    2026-08-16 the unattended window applied a deployment, three deployments accumulated, `/boot`
    hit **26 MB**, this check FAILed and greenboot rejected a **perfectly healthy boot** - then
    could not act on its verdict: *"Boot counter exhausted but no rollback trigger set - manual
    intervention required"*. `rpm-ostree cleanup -r` reclaimed it to 171 MB, the same figure as
    2026-08-14. Nothing is lost by softening it there: the full battery still FAILs hourly into the
    MOTD and `status.json`, and **both reboot paths refuse on their own `df`** - each re-checks
    `/boot` itself against its own `BOOT_MIN_MB=160`, independently of the battery. (Since
    2026-08-17 `bin/reboot-host.sh` hard-gates its pre-flight on `--greenboot` rather than the full
    battery, and prints the rest; that `df` is what still covers `/boot` there.)
  - **`rpm-ostree cleanup -r` removes TWO deployments, not one**, when something is staged: it takes
    the pending update along with the rollback (`deployment count change: -2`), and `greenboot.armed`
    then warns "only 1 deployment, nothing to roll back to" until another stages.
  - **AND THE UPDATE IT TOOK DOES NOT COME BACK ON ITS OWN.** This entry used to say "nothing is
    lost - `rpm-ostreed-automatic.timer` re-stages nightly", which was assumed rather than measured,
    and is false. After the 2026-08-16 `cleanup -r`, the next two automatic runs staged **nothing**,
    the later one exiting in 9 seconds, while a newer amd64 manifest sat on ghcr.io throughout.
  - **`cleanup -r` CANNOT RECLAIM A SLOT HELD BY A PENDING DEPLOYMENT**, which is the case that
    looks identical from `df` and is not. `-r` removes the **rollback**; a deployment that was
    finalized and then not booted sits at index **0**, is not a rollback, and the command exits 0
    reporting *"Deployments unchanged"*. Seen on 2026-08-18 with `/boot` at 26M. The remedy there is
    to **boot it** - see the GRUB fallback entry below - after which it becomes the booted
    deployment, the old one becomes a real rollback, and `cleanup -r` frees the 146 MB.

## The nightly OS updater can silently skip a real update

- **`rpm-ostree upgrade --check` CAN BE WRONG, AND THE NIGHTLY UPDATER BELIEVES IT.** This is the
  mechanism behind the entry above, and it was measured rather than reasoned about: on 2026-08-17,
  within the same minute, `rpm-ostree upgrade --check` reported *"No updates available"* (exit 77)
  and `sudo rpm-ostree upgrade` **staged an update immediately**. The tool warns about this itself -
  *"Note: --check and --preview may be unreliable"*, rpm-ostree issue 1579 - and the consequence is
  not cosmetic, because `rpm-ostreed-automatic.service` is driven by the same check and had
  therefore been skipping a real update every night, in 9 seconds, exiting 0. **So the host can stop
  taking OS security updates indefinitely while every signal reads green.**
  `deploy.update_timer` and `deploy.update_run` prove the timer is armed and that it ran; neither
  can see this, and both were green throughout. `deploy.image_digest` is the check that closes it -
  see the digest trap below, which is the part that is easy to get wrong. **The remedy is
  `sudo rpm-ostree upgrade` by hand**; it worked first try here, and neither `cleanup -m` nor a
  re-`rebase` was needed.

## Checks that could not see the thing they measured

- **A CHECK THAT COUNTS THE UNIT EXECUTING IT WILL BLOCK THE REMEDY FOR ITS OWN CONDITION**, and
  `host.failed_units` did exactly that. `greenboot-healthcheck.service` is what execs
  `verify-host.sh --greenboot`, and a failed unit stays failed for the rest of the boot - so one red
  boot made that check FAIL for ever after, which made `--greenboot` exit 1, which made
  `bin/reboot-host.sh` and `bin/reboot-when-staged.sh` both refuse. **The reboot they were refusing
  is precisely what clears the runtime state.** Escaping it took `systemctl reset-failed` by hand on
  2026-08-16, after the underlying cause was already fixed. That unit is now filtered from
  `host.failed_units` **under `--greenboot` only**, which costs nothing: whatever made greenboot fail
  is measured by that same battery in that same run and reported directly, so the failed unit adds
  no information - it only carries a verdict past the point where its cause was repaired. At real
  boot time it is `activating` rather than `failed`, so the filter is a no-op there and only affects
  the later gated runs, which is where it bit. Same shape as the phantom units the rename left
  behind, and as the self-liveness trap `verify-host.sh` documents about its own timer.
- **THE HOURLY BATTERY SPENT THREE MINUTES A RUN ASKING EVERY REGISTRY A LOCAL QUESTION.**
  `update.policy_count` counted containers carrying an auto-update policy by running
  `podman auto-update --dry-run` - which contacts **every registry for every container** to work
  out whether a newer image exists. Measured 2026-08-18: **3m02s wall against 4.2s of CPU**, i.e.
  essentially the entire runtime of the battery, all of it network wait. Hourly, that is ~500
  registry round trips a day for a number that changes only when a quadlet does - and
  `bin/reboot-host.sh` runs the full battery in its pre-flight, so a human waited three minutes
  for it at the moment they wanted an answer. The policy is a **label**
  (`io.containers.autoupdate`, set from `AutoUpdate=`), so it reads locally in **0.055s**.
  - **It is now exact rather than `>= 20`**, with both sides derived from `stacks/` - the same
    authority `containers.units_active` and the topology lint use. A floor is a magic number
    someone has to remember when a service is added, and this one silently tolerated three
    missing policies.
  - **`podman ps -a`, deliberately**: `podman auto-update` only ever saw RUNNING containers, so
    the number read 21 instead of 23 while caddy and dashboard were down - moving for a reason
    that had nothing to do with what it claims to measure. Whether a container is running is
    `containers.units_active`'s question.
  - **`$repo` WAS READ SEVERAL HUNDRED LINES BEFORE IT WAS ASSIGNED**, found immediately after.
    It lived in the Checkout section, below two checks that now read it; under `set -u` the
    command substitution failed into an empty string and `update.policy_count` reported **"not
    measured"**. A check reading inconclusive from a variable that does not exist yet is the
    quietest way for one to stop measuring - it is not even a WARN. It is defined at the top now.
- **CADDY WAS DOWN FOR 35 MINUTES AND THE BATTERY REPORTED "22 containers up, none unhealthy".**
  The sharpest instance yet of the pattern this file keeps rediscovering, and it took every
  public service down while every signal read green. `caddy-build.service` failed on the
  truncated `policy.json`, so systemd skipped `caddy.service` entirely - *"Dependency failed for
  caddy.service"*. Three checks looked straight at it and none could see it:
  - **`containers.failed_units` counted zero, correctly.** A dependency failure leaves the unit
    `inactive (dead)`, **not `failed`** - there was nothing in a failed state to count. This is
    the one that looks like it should have caught it and cannot.
  - **`containers.healthy` counted what IS running.** A container that never started is not
    unhealthy, it is **absent**, and absent is indistinguishable from "not part of this stack".
    It cheerfully reported 22 up and none unhealthy while the number should have been 24.
  - **`routes.*` only runs under `--routes`**, which is not the hourly path.
  - **The fix is to compare against what SHOULD run**, and the expected set comes from the unit
    files in `stacks/` rather than a list in the script - a hand-maintained roster is the most
    driftable thing here and would need editing in lockstep with every new service.
    `containers.units_active` is that check. Verified by stopping a service: `failed_units` and
    `healthy` both stay green and only the new one fires.
- **`routes.ntfy` ASKED FOR `/`, WHICH IS NTFY'S PUBLIC WEB UI**, so it answered 200 whether the
  instance was deny-all or wide open. The check could therefore only ever FAIL on a correctly
  configured server, and could never have detected anonymous access being opened - a check that
  is wrong in both directions at once. The property lives on a **topic** path, where deny-all
  answers 403 to anonymous including for a topic that does not exist. Measured: `/` -> 200,
  `/home-server/json` -> 403, `/verify-host-probe/json` -> 403.

## Two defects in one uCore image

- **THE SAME IMAGE ALSO SHIPPED AN UNPARSEABLE `policy.json`, AND THAT IS WHY THE PCP MASK WAS
  NOT THE WHOLE STORY.** ucore `e5bf6651` shipped `/usr/etc/containers/policy.json` as **256 bytes
  of the generic containers-common default followed by ~2.5 KB of NUL padding** - the right
  length, the wrong content. It was found only after masking PCP let the image boot.
  - **Nothing could be pulled or built.** Go's JSON decoder rejects trailing NULs -
    `invalid character '\x00' after top-level value` - so every `podman pull`, both `.build`
    units and `podman-auto-update` fail. **22 running containers stayed healthy throughout**,
    because a running container needs no policy, which is exactly why this was invisible.
  - **And the part that DID parse had no `sigstoreSigned` scope at all**, so had the padding not
    been there, ublue's cosign verification would have been silently off while
    `deploy.image_signed` reported it as on. That check reads the **ref**, a string in
    rpm-ostree's metadata; verification depends on a **separate file** that can be absent,
    permissive or unparseable while the ref says `ostree-image-signed:`. `deploy.image_policy`
    is the half that measures it, and it FAILs under `--greenboot`: the breakage ships in the
    image and a rollback is the fix.
  - **DO NOT TEST A POLICY FILE WITH `jq`. It ACCEPTS the broken one** - it stops at the end of
    the top-level value and ignores the padding - so the obvious check passes on precisely the
    input it exists to catch. Python's decoder rejects it the same way Go's does.
  - **The good copy is in the same image**, at
    `/usr/share/ublue-os/signing/usr/etc/containers/policy.json`, and the keys and
    `registries.d/` entries were all byte-identical to pristine - **only `policy.json` was
    damaged**. The repair is `install`ing that copy over `/etc/containers/policy.json`.
  - **THAT REPAIR IS A LOCAL `/etc` OVERRIDE AND OSTREE KEEPS IT FOR EVER**, which is the exact
    thing the image-ref entry below says not to do - a ublue key rotation would then pin this
    host to dead keys and every update would fail. It is accepted here only because the
    alternative was a host that could pull nothing at all. **`deploy.image_policy` now reads BOTH
    files and carries the removal trigger**, because a sentence in this file is the thing nobody
    acts on: it PASSes while the image's own copy is still broken (naming the override as
    load-bearing) and **WARNs the moment the image ships a valid policy that differs**, which is
    exactly what a key rotation looks like. Remove the override then - `sudo rm
    /etc/containers/policy.json` - and confirm podman still pulls.
  - Two independent defects in one build - unlabelled binaries and a truncated file - so treat
    `e5bf6651` as a bad image rather than a bad package. **greenboot's original rejection was
    right for more reasons than the one it named.**
- **PERFORMANCE CO-PILOT IS MASKED, AND IT BLOCKED AN OS UPDATE BEFORE IT WAS.** uCore enables
  `pmcd`, `pmie` and `pmlogger` by default and the two `_farm` units are pulled in by those.
  **Nothing here reads any of it** - cockpit is inactive and the metrics layer is Prometheus,
  node-exporter and `bin/collect-metrics.py`. On **2026-08-18** the published image `e5bf6651`
  shipped `/usr/libexec/pcp/lib/{pmcd,pmie,pmie_farm,pmlogger,pmlogger_farm}` with **no SELinux
  label**, so PID 1 could not exec them - `status=203/EXEC`, `Permission denied`, with
  `avc: denied ... scontext=init_t tcontext=unlabeled_t tclass=file` behind it.
  `host.failed_units` caught it, greenboot rejected the deployment four boots deep and rolled
  back. **That is the system working, and the rollback's first real firing.** But the standing
  consequence was that the host would take **no OS security update at all** while that image was
  published, over a telemetry daemon nobody reads - and no fix was published.
  - **The defect was NARROW, which is what makes masking defensible rather than a shortcut.**
    Exactly those five paths were unlabelled; everything else in the image was fine. Masking
    removes them from `host.failed_units`' view and nothing else, so any *other* unlabelled
    binary a unit execs is still caught. Filtering `pm*` inside the check was the alternative and
    was rejected: it blinds the last line of defence permanently, and the units would go on
    failing, restarting and writing archives.
  - **THE TIMERS ARE `disabled` AND WERE RUNNING ANYWAY**, which is the trap this file already
    names about `Wants=`. `pmie_check`, `pmlogger_check`, their `_farm` and `_daily` variants all
    report `disabled` from `list-unit-files` and were **active and scheduled**, pulled in by the
    three enabled services. Masking the services does not stop them in the running boot - they
    have to be stopped too. Check `list-timers`, not `list-unit-files`.
  - It also reclaimed **268 MB** from `/var/log/pcp` on `nvme0n1p4`, the disk that carries
    `config/`, `/var/backups` and the checkout, and stopped a continuous writer on it.

## greenboot, GRUB, and the red boot that arms the fallback

- **A RED BOOT ARMS *GRUB*, NOT JUST OUR MARKER, AND IT STAYS ARMED UNTIL THE MACHINE BOOTS
  GREEN - WHICH SILENTLY TURNS THE NEXT REBOOT INTO A ROLLBACK.** This is the most expensive
  thing in this file to rediscover, because every signal reads correct while it happens.
  `/boot/grub2/custom.cfg` selects the **previous** deployment whenever `boot_counter` is set and
  `boot_success` is `0`, and `boot_success` is set to 1 only by a green greenboot run. So the pair
  survives the repair: on **2026-08-18**, `bin/reboot-host.sh` was run deliberately, two days after
  the 2026-08-16 red boot, after `/boot` was fixed and `red_boot_at` cleared by hand and the whole
  battery was green. It printed `PASS back after 73s` and `PASS host-level checks pass` - and the
  host came back on the deployment it started from. Four separate things went wrong at once:
  - **THE MARKER NOW RECORDS *WHICH* DEPLOYMENT, NOT ONLY WHEN.** Refusing on a timestamp alone
    was right for the image that failed and wrong for its fix: once a corrected image is
    published nothing could tell the two apart, so the Sunday window kept declining until a
    human cleared the marker by hand - the "host silently stops taking OS security updates"
    failure from a third direction. `50-record-red-boot.sh` writes `red_boot_csum=` from the
    `booted_checksum=` the check wrapper already put in the same file this same boot (no second
    rpm-ostree call on a path that runs when things are already going wrong), and
    `bin/reboot-when-staged.sh` refuses only when `.deployments[0]` carries that checksum.
    **A marker with no checksum still blocks everything** - markers written before this change
    carry no identity, and treating "no checksum" as "no match" would silently release every one
    of them.
  - **`red_boot_at` is ours; `boot_counter` is GRUB's, and only the first was documented.** The
    clearing recipe was `sed -i '/^red_boot_at=/d'`, which disarms the unattended window and leaves
    GRUB pointed at the fallback. `bin/clear-red-boot.sh` now clears both, and
    `greenboot.boot_target` reports the second - it is the check whose absence cost the update.
  - **`ostree admin status` says `(pending)`; `rpm-ostree status --json` says `.staged=false`.**
    ostree has TWO pre-boot states and this repo knew one: **staged** (written, not finalized, no
    `/boot` entry, `/run/ostree/staged-deployment` exists) and **pending** (finalized at shutdown,
    `/boot` entry **written and holding a slot**, `.staged` **false**, and it is what boots next).
    **Six sites selected on `.staged`** and went blind together - the MOTD banner,
    `deploy.image_digest`, the `reboot-host.sh` pre-flight, and worst,
    `bin/reboot-when-staged.sh`, which would have refused *"nothing is staged"* every Sunday for
    ever while the deployment sat ready. All six now use `.deployments[0] | select(.booted | not)`:
    **index 0 is what boots next**, correct in all four shapes, with no state enumeration.
  - **`deploy.image_digest` reported the exact opposite of the truth** - *"a NEWER image is
    published and nothing has staged it ... 'sudo rpm-ostree upgrade' is the first thing to try"* -
    about a deployment that was staged, finalized and entered in `/boot`, while naming the one
    action that could not help. It now separates "nothing has applied it" from "applied but has
    not booted".
  - **A reboot script that verifies HEALTH cannot see this, because a rollback is healthy.**
    `bin/reboot-host.sh` now captures index 0's checksum before rebooting and asserts the booted
    checksum matches it afterwards. On a mismatch it says so and **still unpins** - the deployment
    is fine and merely was not selected, and leaving a pin would hold a third `/boot` slot on a
    partition that has two, making the condition worse.
- **A FINDING WITH NO REMEDY THE ALERT CAN NAME IS AN ALERT THAT TEACHES PEOPLE TO IGNORE ALERTS**,
  and `greenboot.verdict` was one. A red boot writes `greenboot_result=red` into
  `/var/lib/home-server/boot-state`, and that is a fact about **this boot** - only a reboot rewrites
  it. So the check FAILed indefinitely, firing `CheckFailing` at critical every 4h, for up to a
  week given the Sunday window. Everything around it cleared normally: `/boot` was repaired,
  `deploy.boot_free` went green, `red_boot_at` was cleared by hand, `greenboot.red_boot` went green -
  and this one kept shouting about an event from two days earlier that nobody could act on. Exactly
  the "send enough of them that the critical ones stop being read" failure the Alerting section is
  written against.

  **The acknowledgement already existed; the check simply did not read it.** `red_boot_at` is the
  actionable FAIL - it holds unattended reboots and has a documented clearing procedure that asks
  the only question worth asking. `greenboot.verdict` is the descriptive half. It now FAILs while
  `red_boot_at` is present and **WARNs once a human has cleared it**, naming that the next boot is
  what rewrites the verdict. One event, one FAIL.

  **THAT DOWNGRADE WAS UNSOUND UNTIL A SECOND, MISSING CHECK WAS ADDED, and the gap is the more
  serious half of this entry.** An absent `red_boot_at` has two readings - acknowledged, or the
  `red.d` hook never ran - and boot-state cannot tell them apart. `greenboot.armed` asserts the
  check is in `required.d` and that the GRUB counter exists; **nothing asserted
  `50-record-red-boot.sh` was symlinked into `/etc/greenboot/red.d/`**, which is the hook that
  breaks the loop FCOS's own documentation names: after a rollback nothing tells the updater the
  image was bad, so it stages the same digest again within the day. Its absence is silent in the
  worst way - every greenboot check still passes, a red boot still rolls back, and the only
  consequence is that the mark is never written, so the unattended window re-applies the same
  rejected deployment the following Sunday, for ever. `greenboot.red_hook` now asserts it, and is a
  prerequisite for the softening above rather than a nicety. Both live outside `--greenboot`, so
  neither can block a reboot.

## A digest that is not comparable, and a marker a reboot wipes

- **TWO SHA256 DIGESTS NAME THE SAME IMAGE, AND COMPARING THE WRONG PAIR IS WRONG FOR EVER.** The
  obvious way to ask "is the booted OS image current" is to compare `rpm-ostree status --json`'s
  `container-image-reference-digest` against `skopeo inspect`'s `.Digest`. **Those are different
  kinds of digest**, so that check fires on every host, on every run, on a perfectly current
  machine - and it looks completely reasonable while doing it. Verified by fetching each back:
  rpm-ostree records the **platform manifest** (`application/vnd.oci.image.manifest.v1+json`), while
  `skopeo inspect` reports the **image index** (proved by `skopeo inspect --raw | sha256sum`, which
  equals it). `ucore:stable-nvidia-lts` is a two-entry index, `arm64/linux` and `amd64/linux`, so
  the remote side must be resolved through `skopeo inspect --raw` to **this host's architecture**
  before it means anything - and the architecture must come from `podman info` (`amd64`), not
  `uname` (`x86_64`). This is the same class as the `home_server_container_memory_high_bytes` naming
  decision: **a wrong number under a right name is undetectable from a dashboard.** Assert the two
  sides are comparable before believing a digest check.
- **`ExecMainExitTimestamp` is runtime state and a reboot wipes it**, so "this nightly job has never
  run" and "it has not run in the twenty minutes since boot" look identical. `bin/verify-host.sh`
  therefore only treats a missing run as a finding once uptime exceeds the timer's period -
  otherwise every reboot produced a day of false warnings, which is precisely how someone learns to
  ignore the one line that matters.

## Disks, and where things must not be put

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

## The segmentation, and what it buys

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

## Logs, and why priority is not a signal

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

## The media spindle, measured

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

## Jellyfin and the transcode pipeline

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

## cgroup limits, and the controller that was not delegated

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

## Indexers

- **The ISP resolver returns a blocking page for several indexer domains.** All three distinct
  1337x hostnames resolved to one address, `193.191.210.104`, and four indexers failed as "DNS/SSL
  issues" while every container looked healthy. `prowlarr` and `flaresolverr` therefore carry
  `DNS=9.9.9.9` / `DNS=1.1.1.1`. Measured from a throwaway container: the request that dies at the
  sinkhole reaches the real Cloudflare-fronted host and returns a 403 challenge, which is exactly
  what FlareSolverr is on `net-solver` to solve. **A DNS failure here looks like an application
  fault, so compare a suspect hostname against a public resolver before believing the site is down.**
- **THE DNS OVERRIDE WORKS, AND IT IS NO LONGER THE EXPLANATION FOR A DOWN INDEXER.** The entry above
  is why the override exists and stays true as history; it stopped being the diagnosis. Checked on
  2026-08-15 when `home_server_indexer_up` read 0 for six of seventeen: `DNS=9.9.9.9` **is** in
  effect - aardvark-dns records `9.9.9.9,1.1.1.1` as prowlarr's upstream, and a container's
  `resolv.conf` naming the bridge gateway is normal rather than evidence against it - FlareSolverr
  was healthy and solving challenges in ~11 s, and every failing hostname resolved to a plausible
  public address. **The six zeros were five unrelated causes**, none of them DNS: a dead mirror
  (`1337x.st`, cert name mismatch), its exact duplicate, two Pirate Bay entries that query the same
  `apibay.org` host as a third and so tripled the load on something already returning 503, a 502 and
  a 403. Four entries were deleted; the remaining zeros are other people's sites being down, and are
  now *correct*.
- **Prowlarr pushes every indexer to every application and retries the refused ones for ever.** One
  indexer, `Nyaa Trusted - Live Action`, returned results in Prowlarr category `129933` - the
  unmapped `>=100000` range - which is neither `5000:TV` nor `2000:Movies`, so Sonarr and Radarr both
  refused it correctly and Prowlarr re-offered it every six hours, four `400 BadRequest` at a time,
  at WARN. It had never delivered anything. **The gap is invisible by design**: nothing compares the
  three indexer counts, which is why `home_server_arr_indexers{service=...}` now reports all three.
  **Some gap is correct** - a movies-only indexer belongs in Radarr and not Sonarr - so read the
  three numbers and the log; do not alert on equality.
