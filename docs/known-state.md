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
- **BUT JOAL IS INSIDE THAT NAMESPACE, AND THAT IS THE PART THE SENTENCE ABOVE UNDERSTATES.**
  Re-examined 2026-08-19. The three containers share one network namespace, so `127.0.0.1` is common
  to all of them - and `bypass_local_auth: true` means anything in that namespace reaches
  qBittorrent's WebUI **with no credential at all**. gluetun is the one that needs it:
  `VPN_PORT_FORWARDING_UP_COMMAND` posts to `/api/v2/app/setPreferences` unauthenticated on every
  reconnect. JOAL gets the same reach for free, and JOAL is third-party software whose whole job is
  talking to trackers - so it is the least trustworthy thing in the pod holding an unauthenticated
  path to the client that owns the download directory.
  **It is recorded rather than fixed, and the reason is worth keeping.** The obvious repair is to
  make the up-command authenticate, and it does not work cleanly: gluetun ships busybox `wget`,
  which has no `--save-cookies`, so acquiring and replaying a qBittorrent SID means scraping
  `Set-Cookie` out of `-S` stderr inside a quoted systemd `Environment=` line - more moving parts in
  the path that keeps the kill-switch working than the exposure justifies. The alternatives are
  worse: a subnet whitelist cannot separate two containers that share an address, and moving JOAL
  out of the pod would have it announce from the host's own IP, which is the reason it is in there.
  **What would actually close it is dropping JOAL**, and that is a decision about whether ratio
  padding is wanted at all, not a networking fix.
- **THE DAILY PASSKEY PROMPT WAS A STOCK DEFAULT NOBODY CHOSE, AND IT IS ABSOLUTE RATHER THAN
  IDLE-BASED.** Tinyauth's `sessionExpiry` is 86400 - one day - and nothing in this repository set
  it, so sign-on had inherited the value since the day it was built. The expiry is stamped at login
  and never refreshed, which is the part that makes it feel like a fault: using the stack constantly
  does not extend it, so the prompt arrives every day no matter what. Three independent
  measurements, because the first plausible theory was wrong: `tinyauth config` read back
  `sessionExpiry: 86400` from the running process; both rows in `tinyauth.db` had
  `expiry - created_at` of exactly `86400`; and Pocket ID's audit log showed sign-ins 24.05h,
  24.57h, 24.76h and 24.25h apart, **drifting later each day** and jumping to 48.09h on a day the
  stack went unused - the signature of a rolling clock rather than a scheduled event.
  **It is NOT the nightly `AutoUpdate=registry` recreating the container**, which is the theory that
  fits at a glance and predicts a fixed time of day rather than a drift. Sessions live in
  `tinyauth.db`, a bind mount, so they survive a restart: `tinyauth.service` and `pocket-id.service`
  both read `NRestarts=0` across a pair of sign-ins a full 24h apart inside one unbroken uptime.
  That is also what makes revoking a session a `DELETE` from that table plus a unit restart rather
  than a wait. Now `TINYAUTH_AUTH_SESSIONEXPIRY=2592000`, thirty days.
- **The passkey CEREMONY, as opposed to its frequency, is a second clock - and it was left alone.**
  Pocket ID's own `SESSION_DURATION` is also unset, default 60 minutes, so by the time Tinyauth's
  cookie dies Pocket ID has long forgotten the browser and cannot answer the redirect silently.
  Raising it would make the rollover a silent redirect and was **declined**: the whole value of this
  design is that renewal costs a real WebAuthn signature from the device rather than a cookie
  renewing itself unattended. Worth knowing before someone reads the 60-minute default as an
  oversight and "fixes" it.
- **A session's expiry is written at creation, so changing the setting does not touch sessions that
  already exist.** After the deploy above there was one more daily prompt before the first
  thirty-day session existed. A rollover on the old schedule is therefore not a failed deploy, and
  the clock is the wrong thing to check - read `expiry - created_at` off the new row instead.

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
- **`ContainerRestartLoop` COULD NOT FIRE, AND HAD NEVER BEEN ABLE TO.** It read
  `home_server_container_restarts_total`, which the collector took from podman's per-container
  `Restarts` field - and a quadlet **recreates the container on every unit restart**, so the counter
  resets each time round a loop rather than accumulating. Measured against the one event it was
  written for: through all 6,224 of Pocket ID's restarts on 2026-08-19 the series read **0**, for
  nine and a half hours. The rule was `increase(...[1h]) > 5` against a gauge that is structurally
  pinned at zero. `source_units()` now reads systemd's `NRestarts`, which belongs to the **unit** and
  therefore outlives the containers it creates, and the rule is `UnitRestartLoop`. The old series is
  kept, because it does say one thing the new one cannot - a container restarting *without* its unit
  restarting - but its help text no longer claims to be the restart count. **The general shape: a
  counter that resets is not a counter, and the reset condition here was the exact condition being
  measured.**
- **`Restart=always` AT `RestartSec=5` CANNOT REACH SYSTEMD'S START LIMIT, SO NO UNIT HERE EVER GAVE
  UP.** The shipped ceiling is 5 starts in 10s; five-second spacing produces at most two, so the
  limit was arithmetically unreachable on all 23 quadlets and none of them set their own. Pocket ID
  oscillated between `failed` and `activating` 6,224 times over nine and a half hours rather than
  coming to rest. **This was NOT a detection failure and must not be recorded as one** -
  `containers.units_active` and `containers.failed_units` both went FAIL within the hour and stayed
  there, and `CheckFailing` went critical. What was missing was an end state: `StartLimitIntervalSec=600`
  with `StartLimitBurst=20` now stops it after ~100 seconds, which is what makes `home_server_unit_state`
  worth reading, and a slow dependency at boot still gets twenty attempts before it counts.
- **ALERTMANAGER WAS A DESTINATION AND NEVER A SCRAPE TARGET, SO THE LAST HOP TO THE PHONE WAS
  UNMEASURED.** It appears in `prometheus.yml` under `alerting:`, which makes it somewhere to *send*
  alerts - a different relationship from being collected from, and the two look alike enough in that
  file that nobody noticed. The consequence is precise: `alertmanager_notifications_failed_total` is
  exactly the 401-against-the-read-only-mount that `alertmanager.yml` warns about **in its own
  comments**, and it existed nowhere anything could read it. `AlertDeliveryFailing` covers
  Prometheus -> Alertmanager and was the only hop watched, of four.
  **It is also why 2026-08-19 cannot be reconstructed.** Four critical alerts fired continuously
  from 01:00 to 09:30; `ntfy-alertmanager` does not log the webhooks it receives, so there is no
  record on this host of whether a single page was delivered - and both counters that could have
  said so were reset by a restart before anyone looked. Now scraped, with `AlertBridgeFailing` and
  `metrics.alert_bridge`, plus a `Watchdog` that always fires at a 24h repeat so a **silent** phone
  means a broken chain rather than a quiet stack.
- **THE ONE JOB THAT PROVES THE BACKUPS RESTORE WAS THE ONE JOB WITH NO RECORD.** Every other leg
  writes a marker and `verify-host.sh` grades it - `local_at`, `offsite_at`, `offsite_pruned_at`,
  `offsite_policy_ok_at`, `tsdb_snapshot_at`, `pre_update_db_at`. `bin/verify-restore.sh` wrote
  nothing, so "nobody has run this since March" and "this ran last night" were the same observable
  state. CLAUDE.md states the rule in the abstract - an automated job needs a durable record of its
  last success - and this was the job it had never been applied to. **`RestoreNeverProven` keys on
  the CHECK and not on the marker's age**, because a staleness rule needs the series to exist and the
  state that has to be covered is a marker never written at all.
  **Running it immediately found something.** `bin/verify-restore.sh` with no arguments verifies the
  WORKSTATION's copy at `~/backups/home-server` - the third copy, written by hand by
  `bin/backup-config.sh` - and its newest snapshot was **2026-08-15**, four days old and predating
  ntfy, so it FAILed on a missing `ntfy/auth.db`. Nothing tracks the freshness of that third copy:
  `offsite_pruned_at` records the workstation's *prune*, and there is no marker for the copy itself.
- **A DUMP OUTLIVES ITS OWN ACCURACY, AND TWO CORRECT DECISIONS ARE WHAT MAKE IT DO SO.**
  `windmill-db` is Postgres, so it is excluded from the file copy and captured by `pg_dumpall` into
  the shadow tree instead. Two properties that are right on their own combine badly: the shadow tree
  is **deliberately never deleted** between runs, so restic only transfers what changed, and
  `--filter='protect /windmill-db/'` **deliberately keeps last night's staged copy**, so
  `--delete-excluded` cannot remove it. Together they mean that if the database stops, its last dump
  stays in both places and is re-snapshotted every night, **indefinitely, looking exactly like a
  fresh one**. A restore verification would pass on it a year later.
  The split is the fix, and it is why the two halves live in different scripts on different machines:
  `bin/verify-restore.sh` asserts only that a dump EXISTS and is whole - present, ends with
  pg_dumpall's own `-- PostgreSQL database cluster dump complete`, carries a `CREATE ROLE` - and says
  nothing about age. `backup.windmill_dump_age` asserts recency, on the server, because that is the
  only place where "is the container even running" can be answered. **The marker is therefore written
  by `bin/snapshot-databases.sh` and only on a real dump**, never on a skip: it is the one place that
  can tell the two apart, since the exit status cannot and neither caller can.
  It also NOTEs rather than warns when `windmill-db` is down, because a stopped database is
  `containers.units_active`'s finding and a second WARN would only block the reboot window over
  something a reboot does not fix.

- **And `LoadState` cannot tell you whether that unit file exists.** Found on 2026-08-21 while
  teaching `conduct` to place itself in the slice: **systemd SYNTHESISES slice units on demand**, so
  `systemctl --user show app-agents.slice -p LoadState` returns `loaded` on a workstation that has
  never heard of it, while a missing `.service` on the same machine correctly returns `not-found`.
  The discriminator is `FragmentPath`, which is empty exactly when no file backs the unit. This is
  the same fact as the entry above seen from the querying side: there is nothing to fail, so nothing
  fails, and the obvious check reports success.

- **`systemctl show` reports a unit that does not exist as `inactive`, with exit status 0.**
  Identical output to a real unit sitting idle - `LoadState=not-found` is the only difference, and
  nothing forces you to ask for it. So any hand-maintained list of units to watch is a check that
  stops working silently the moment a name is renamed or misspelt: it reads "nothing is busy" for
  ever and can never fire. `conduct`'s refusal cascade fetches `LoadState` and `ActiveState` in one
  round trip for that reason, treats `not-found` and `masked` as faults in the LIST rather than as
  states of the host, and `conduct doctor` resolves the whole watchlist on demand. **The faults are
  reported and never refused on**: a wrong name must be loud without wedging the fleet, which would
  trade a blind gate for a stuck one. `is-active` is worse and not the fix - its exit codes are not
  uniform, 3 for real-but-inactive against 4 for missing.

- **Asking `rpm-ostree` a question starts the daemon you were asking about.**
  `rpm-ostreed.service` read `inactive`; after a single `rpm-ostree status` it read `active` /
  `running` and stayed that way. It is D-Bus-activated, so **a monitor polling that unit's
  `ActiveState` to decide whether an OS update is in progress flips itself to "busy" on its own
  first poll**, and then stays busy. The question that survives being asked is the `transaction`
  field in `rpm-ostree status --json` - `null` when idle, however often it is read - or the
  `ActiveTransaction` property on the Sysroot object. `rpm-ostreed-automatic.service` is safe to
  poll and is the complementary signal, being the unit that actually stages a deployment.

- **Two `RemainAfterExit` oneshots read `active` for the entire boot while being permanently idle**:
  `greenboot-healthcheck.service` and `ostree-remount.service`. That is the exact mirror of the
  oneshot trap `bin/reboot-when-staged.sh` records - there a oneshot was `activating` for its whole
  working life and never `active`; here one is `active` for the whole life of the boot having
  finished in seconds. Anything treating `active` as busy would refuse for ever, so `conduct` keeps
  an explicit never-watch list with a test rather than widening its allowlist.

- **A `Slice=` naming a slice with no unit file does not fail - systemd instantiates it with
  defaults, and every signal reads correct.** `host/systemd/app-agents.slice` is the aggregate
  ceiling the coding-agent fleet runs inside, and the only thing that bounds it: its phase runners
  are `podman run --rm`, so their count is a variable and no sum of per-unit ceilings can reach it.
  If the unit file is not symlinked into `~/.config/systemd/user/`, systemd creates the slice
  anyway, with no limits at all - and every member then starts, stays healthy, stays fully observed
  by Prometheus and is contained by nothing. **This is the `io`-delegation failure one directive
  over**, which was inert here for months for the same reason: the directive is accepted and does
  nothing. `agents.slice_limits` is what closes it, and it reads `memory.max`, `memory.high`,
  `cpu.max`, `io.weight` and `pids.max` back out of the cgroup rather than out of the unit file -
  `systemctl --user show` would report what the file SAYS, which is the half that was never in
  doubt. It asserts they are *set*, not their exact figures, because an exact assertion would be a
  second copy of the slice in a place nothing reconciles. Unlimited spells itself differently per
  controller and all five spellings were read off this host: `max`, `max`, `max 100000`,
  `default 100`, `max`.
  **The symlink loop in `host/systemd/README.md` globs by EXTENSION, which is its blind spot.** It
  was `*.service *.timer` and was widened to `*.slice` in the same commit. A glob cannot drift
  within the extensions it names and is completely blind outside them - and the README's own
  argument for globbing ("a glob cannot drift") reads as though it covers this, and does not.
- **The collector's cgroup join was flat, so the first unit ever placed in a slice would have gone
  dark.** `bin/collect-metrics.py` built one path, `CGROUP + "/" + unit`, where `CGROUP` ends in
  `app.slice` and `unit` is podman's own `PODMAN_SYSTEMD_UNIT` label. `Slice=app-agents.slice` puts
  the cgroup one level deeper, `os.path.isdir` misses, and the container is counted in
  `home_server_container_identity_unresolved` and otherwise dropped. **What is lost is 32 of
  `windmill-db`'s 43 series** - working set, rss, cache, the inactive/active split,
  pgscan/pgsteal/refault, both memory ceilings, all four `memory.events`, CPU, PSI for three
  controllers, `io.stat` per device, pids. The 11 that survive are the ones `podman ps` and
  `systemctl` answer, so the container looks entirely normal on every other signal.
  `_unit_cgroup()` resolves it: the flat path first, so nothing that resolves today can move, then
  **one level** of `*.slice`. One level rather than a walk because systemd derives the hierarchy
  from the dashes in the name, so the depth is knowable - and because a recursive search would also
  match the `libpod-payload-<id>` cgroup nested INSIDE the directory being looked for, which is a
  different set of numbers that would look entirely plausible.
  **Not `/proc/<pid>/cgroup`, which is the obvious authoritative answer and is wrong here.**
  `torrent-infra` reports the POD's cgroup, `user@1000.service/user.slice/user-libpod_pod_<id>/...`,
  which contains its unit name nowhere; the flat join resolves it to `app.slice/torrent-pod.service`,
  the unit's own cgroup. Switching would have silently changed what the four pod members' numbers
  mean while every one of them kept reporting.

- **"A container" meant "a quadlet" everywhere, and six readers each assumed it away differently.**
  `conduct` starts its phase runners and their datastores with `podman run --rm`: no
  `PODMAN_SYSTEMD_UNIT`, a lifetime of minutes, and a name carrying a worktree id. Measured with one
  throwaway busybox on `net-agents`, against the code as it stood: `home_server_container_identity_
  unresolved` went 0 -> 1 (a counter whose help text says that means the join has broken, and which
  the Services page renders as *"N container(s) could not be mapped to a systemd unit, so they are
  absent from this table"*); `home_server_containers` went 25 -> 26; `containers.healthy` reported
  *"26 containers up"*; and two `home_server_container_network_*` series appeared labelled with the
  throwaway's name. **The `container` label had exactly twenty-five values and had never grown.**
  The skips are keyed on the PRESENCE of `io.home-server.ephemeral`, never its value: a bare
  `--label io.home-server.ephemeral` yields `""`, and a truthiness test would read that as "not
  ephemeral" and silently restore all of it. `podman ps --filter label=<key>` matches on presence
  too, so the shell and the Python agree without either restating the rule.
  **The two collector skips look identical and are different bugs.** `source_containers` already
  emitted nothing for an unlabelled container, so its damage was purely the lying counter;
  `source_container_network` has no unit check at all, so its damage is real cardinality - and
  retention here is **400 days** while `metrics.series_count` grades `prometheus_tsdb_head_series`,
  live series only, compacted out after about two hours. **The budget check cannot see persisted
  churn**; only `metrics.tsdb_size`, at its 18 GB ceiling, would ever notice.
- **Three of those seven readers are closed by a flag rather than by code, and that is the better
  fix.** `containers.healthy`, `containers.probe_binaries` and `logs.healthcheck_events` all read
  the health *state* of whatever `podman ps` returns, and only misbehave when a container inherits a
  `HEALTHCHECK` from its base image - which the fleet's datastores plausibly do and nobody controls.
  `--no-healthcheck` on every `podman run` `conduct` issues closes all three at the source, where
  three defensive filters would each have to stay correct for ever. **`containers.healthy` is
  filtered as well anyway**, because it is the only one of the seven whose failure is a FAIL rather
  than a WARN, and a FAIL blocks `bin/reboot-host.sh` and therefore an OS security update.
  **`grep -vxF ""` matches every line**, so the subtraction has to short-circuit when nothing is
  ephemeral - otherwise the normal case filters out all twenty-five containers and PASSes with
  *"0 containers up, none unhealthy"*. The failure appears only when nothing is wrong.
- **DO NOT "FIX" THE SKIP BY GIVING A RUNNER A UNIT LABEL.** This is the trap the skips create and
  it is invisible for thirty days. `apps/dashboard/src/pages/SystemPage.vue` renders the **worst
  five** containers by 30-day availability, sorted ascending on
  `avg_over_time(home_server_container_running[1h])`. A runner that lived twenty minutes and emitted
  that series would score about 0% for its day, **evicting a real row from the strip for a month** -
  and the next runner would evict another. The strip's own sizing comment says "twenty containers",
  which is the assumption that quietly stops holding. Runners must stay absent from
  `home_server_container_running` entirely, which is what the skip in `source_containers` guarantees.
- **A WINDMILL WORKER'S TAGS ARE UNVERSIONED STATE THAT HOT-RELOADS, so the one-verify-lane
  invariant does not live in the file named after it.** `windmill-worker-verify.container` carries
  `WORKER_TAGS=verify`, and that is a **bootstrap**: Windmill keeps worker-group configuration in
  its `config` table - which ships with `worker__default`, `worker__native` and `worker__reports`
  already seeded, each holding an explicit `worker_tags` array - and workers watch that table and
  reload from it. Create a `worker__verify` row from the UI and it **wins, at run time, with no
  restart, and `git diff` shows nothing**. Measured with a throwaway worker before either unit
  shipped: with no such row, `WORKER_TAGS=verify` produces `custom_tags={verify}` and no row is
  auto-created - so the bootstrap works today and would be silently superseded tomorrow. One file
  enforces one container; it does not enforce what that container listens to. `agents.worker_lanes`
  reads `custom_tags` back out of the database hourly, which is the same argument
  `agents.slice_limits` makes one level up. Note also that **advertising a tag is not the same as
  being able to select it**: `global_settings.custom_tags` is Windmill's "Assignable Tags" and reads
  `["chromium"]`, so routing a flow step to this lane needs the tag added there too.
- **A WINDMILL WORKER SERVES NO HTTP, so the probe every other unit here uses does not exist - and
  the failure it would have to catch is invisible to every other reader.** `windmill --help`, read
  out of the image, documents `PORT` as the "**server**/indexer/MCP" port and `METRICS_ADDR` as EE
  only; the binary contains no `healthz` route. A worker does start an HTTP server, on a **random**
  port bound to `127.0.0.1` - measured at 42881 - which is unreachable and unpredictable. The
  tempting answer is no healthcheck at all, where `duckdns` and `unpackerr` sit. It is the wrong one
  here: these units follow a floating **patch** tag and are restarted nightly, so without
  `Notify=healthy` the auto-update rollback is decorative, and what it would miss is a worker that
  starts, registers nothing and takes no jobs - **no unit failed, no container unhealthy, nothing in
  `podman ps`, and work simply queues**. So the probe is a `psql` query asserting a fresh row in
  `worker_ping`, which makes it the only health probe on this host that asks a **second** container
  whether the first one is doing its job. `psql` is safe to depend on for the reason `curl` was in
  `windmill-server`: upstream installs `postgresql-client` **by name** in its final runtime stage.
  Two things it deliberately does not do - it does not assert the tags (that would fail a start
  after a UI change and roll back an image that was never the problem), and it does not use
  `$DATABASE_URL`, because systemd expands `$VAR` in the generated `ExecStart` from
  `EnvironmentFile=` **only**, and `DATABASE_URL` is assembled in `[Container]`, so it would reach
  podman as the empty string.
- **`worker_ping` HOLDS A ROW PER WORKER *NAME*, AND THE NAME IS REGENERATED ON EVERY START**, so
  anything that counts rows over-counts for the whole freshness window after a restart - including
  every nightly `podman auto-update`. Windmill mints `wk-<group>-<host>-<random>` at boot and never
  deletes the old row; it only goes stale. Measured immediately after a deliberate restart: two
  containers running, **four** fresh rows, and `/api/health/status` reporting `workers_alive:4`.
  `agents.worker_lanes` was written the obvious way and duly reported the verify lane as *"drifted
  to [verify verify]"* - a check firing on the thing working, which is the failure mode that gets a
  check switched off. It asserts the **set** of tag lists per lane now, never the count; the count
  is a property of there being one quadlet file per lane and `containers.units_active` already
  covers it.
- **A `chcon` is what lets a phase read its own worktree, and nothing versions it.** The runner
  bind-mounts the worktree with neither `:z` nor `:Z`: `:z` relabels the *source*, which by the
  second phase holds a 607 MB venv and a 368 MB `node_modules`, and `:Z` locks out every other
  container mounting the same tree. So the fleet root is relabelled once by hand and SELinux type
  inheritance carries it - **measured, not assumed**: a file created under a `container_file_t`
  directory comes out `container_file_t` whether `conduct` creates it from the host as
  `unconfined_t` or a phase creates it from inside a container. `chcon` is not durable, though: a
  `restorecon -R /var` or a relabelling reboot resets the tree, every phase then dies on a
  permission error naming SELinux nowhere, and `git diff` shows nothing because the label was never
  in git. The durable form needs `semanage`, in a package this host's rules argue against layering,
  so `agents.fleet_root_label` is what says the label has been undone.
- **`--security-opt label=level:s0` was specified to fix a trap this design does not have, and
  shipping it would have made containment WORSE.** The premise was that podman assigns each
  container a random MCS pair, so run 2 gets EACCES on a venv run 1 wrote - a failure that appears
  only on the second run and reads as corruption rather than as permissions. Measured over four
  consecutive containers with pairs `c540,c855` / `c85,c222` / `c38,c807` / `c42,c357`: **every file
  each one created came out `container_file_t:s0` with no categories at all, and every run read
  every earlier run's files.** The categories come from `:Z`, which relabels the mount source with
  the container's pair - the control case produced `container_file_t:s0:c282,c750` - and this design
  uses neither `:z` nor `:Z`. So the flag would have bought nothing and cost the per-container MCS
  separation that is there for free. Dropped, on the measurement, exactly as `BASE_INTERNAL_URL`
  was.
- **`isolate=true` blocks more than "other podman bridges", and the plan asserted the weaker
  claim.** It was written down that an agent could reach `https://192.168.0.100/` and everything
  Caddy fronts, because a host publish is not a bridge. Measured from an isolated bridge against a
  plain one: **Caddy's 443 and Jellyfin's 8096 both time out on the isolated network and both
  connect on the plain one.** Reaching a published port at the host's LAN address DNATs into the
  owning container's bridge, so it is a bridge-to-bridge flow after all. What is genuinely not
  blocked is the host itself - port 22 is **refused** from both, which means the packet arrived -
  and the internet, which is what makes `bun install`, `uv sync` and `gh` work at all. Read the
  distinction the way `docs/networking.md` insists: **124 from `timeout` is a blocked edge, 1 is a
  shut port.**
- **`Persistent=true` does not cover the first install, and a unit comment here claimed it did.**
  `systemctl --user enable --now` writes `~/.local/share/systemd/timers/stamp-<timer>` immediately,
  so there is no missed elapse to catch up on and the timer does not fire - measured, with the stamp
  dated the second the timer was enabled and `list-timers` showing `LAST -`. Harmless for every
  other timer here, because each built image is pulled into the dependency graph by a `.container`
  that names it. **Nothing references `conduct-runner`**, so on a host that has never run that unit
  the phase runner image does not exist and nothing produces it before the first Saturday - at which
  point `conduct` has no `:latest` to run. The one-time `systemctl --user start` is part of the
  setup in `host/systemd/README.md`, beside the symlink loop.
- **`Nice=` cannot be set on a transient scope**, and `systemd-run` says so with `Unknown assignment:
  Nice=10` rather than ignoring it - which is the good outcome, since the phase runner's whole
  invocation would have failed to start. It is an exec property, and a `--scope` is not started by
  systemd; the process is the caller's. `nice -n 10 podman run ...` is the replacement, and the same
  applies to every other exec-context directive somebody is tempted to pass with `-p`.
- **A read-only rootfs turns every cache environment variable into a required mount.** The runner
  image sets `UV_CACHE_DIR`, `BUN_INSTALL_CACHE_DIR` and `PLAYWRIGHT_BROWSERS_PATH` to fixed `/opt`
  paths precisely so they are mountable, and with `/opt/bun-cache` left unmounted `bun add` dies
  with `bun is unable to write files to tempdir: ReadOnlyFileSystem` - naming neither the variable
  nor the path, and reading as a broken image rather than as a missing `-v`.
  `bin/conduct-runner-smoke.sh` runs one `bun add` to cover the whole class.
- **`node:24-trixie-slim` ships no `python3`, no `git` and no `make`** - `ca-certificates curl wget
  gnupg dirmngr xz-utils libatomic1` is the entire apt list, read out of `nodejs/docker-node`'s own
  Dockerfile. Six of upskald's eight `make check-gate` targets shell out to `python3`, so the
  obvious base image fails the gate at its first line. Every import in those scripts is stdlib, so
  one apt package settles it and there is no pip layer. Trixie also renamed `libmagic1` to
  **`libmagic1t64`** in the 64-bit `time_t` transition, and `api/pyproject.toml` depends on
  `python-magic`.
- **Two writers share one exposition file, and a name collision rejects THE WHOLE SCRAPE.**
  `bin/verify-host.sh` records facts; `source_status` in `bin/collect-metrics.py` mints
  `home_server_<fact key>` for every numeric one; and that file's own `m.add()` names land beside
  them. Prometheus tolerates a duplicate sample whose value matches and rejects the entire scrape
  when it does not - and these two disagree by construction, because the battery is hourly and the
  collector runs every thirty seconds. So the failure is not one wrong panel: it is every metric on
  the host disappearing, waiting on whichever pair of samples first drifts apart. The collector
  carries `FACT_OWNED_ELSEWHERE` for the one collision it wants, and that comment records how the
  trap was found - "by reading the exposition rather than by the check, which stayed green
  throughout". **`bin/lint-repo.sh` leg 9 is now that check**, statically, because the runtime
  version needs the two writers to disagree first.
- **The battery's agent facts and the collector's agent metrics are ONE LETTER APART.** The facts
  are `agents_*`, plural, and become `home_server_agents_*`; the collector's family is
  `home_server_agent_*`, singular. Two files, neither mentioning the other's spelling at the point
  it matters, and the penalty for confusing them is the entry above.
- **A lint leg that greps for `m.add("literal")` cannot see a name built by concatenation**, and the
  first version of leg 9 proved it by passing with a deliberate collision planted in front of it.
  Most names in `bin/collect-metrics.py` are built as `"home_server_agent_" + suffix` inside a loop,
  so the grep captures the PREFIX and never the name. The leg reads every `home_server_` string
  literal instead and treats one ending in `_` as a prefix that shadows every key beneath it -
  **except the bare `home_server_`**, which is `source_status`'s own bridge and, left in, matches
  every candidate and fails all ninety. Passing on everything and failing on everything are the same
  uselessness in opposite directions, and the negative control is what tells them from a check that
  works.
- **`ActiveState` reads `active` for a long-running unit whether it is busy or idle**, which is the
  exact mirror of the trap `bin/reboot-when-staged.sh` already carries about `home-server-backup`:
  a `Type=oneshot` is `activating` for its entire working life and never `active`. Both are the
  obvious question to ask systemd, both read correctly, and both are dead. So the phase-in-flight
  refusal reads a marker `conduct` writes about itself - **and only believes it while the heartbeat
  is fresh**, because a conduct killed mid-phase leaves the flag set for ever and a stale veto is
  the "host silently stops taking OS security updates" failure from a fourth direction.

## The orchestrator, and four assumptions its first live run contradicted

**`Environment=` does not expand `${VAR}` from `EnvironmentFile=`, and the failure is silent.**
The obvious unit - `EnvironmentFile=/var/home-server/.env` plus
`Environment=CONDUCT_STATE_DB=${DOCKER_VOLUME_CONFIG}/conduct/conduct.db` - hands the process that
dollar-sign string verbatim. Measured with a throwaway unit on the host: `$DOCKER_VOLUME_CONFIG`
read correctly in `ExecStart=` and the interpolated `Environment=` value came through as the literal
`${DOCKER_VOLUME_CONFIG}/conduct/conduct.db`. Expansion happens in `ExecStart=` and nowhere else.

What makes it worth an entry rather than a fix is which direction it fails in. `os.makedirs` on a
path beginning `${DOCKER_VOLUME_CONFIG}` does **not** raise - it creates a directory of that literal
name, in whatever the working directory happens to be. So the state database would have existed, and
been written, and been outside the tree `bin/snapshot-databases.sh` walks, and nothing anywhere would
have reported a problem. Units here pass no interpolated `Environment=`; the program reads
`DOCKER_VOLUME_CONFIG` and `DOCKER_VOLUME_CACHE` itself.

**A detached `podman run` lands outside `app-agents.slice`, and the runner does not.** Read out of
`/proc/<pid>/cgroup` during a live phase: the phase runner resolves to
`.../app.slice/app-agents.slice/conduct-check-<id>.scope/libpod-<id>.scope`, because it runs under a
transient scope with `--cgroups=split`; its three datastores resolved to
`.../user@1000.service/user.slice/libpod-<id>.scope`, outside the fleet ceiling entirely. They have
no scope, so they need `--cgroup-parent=app-agents.slice`, and an aggregate limit with three
unaccounted members underneath it is worth having only if it says so.

That flag has the failure mode this repository already names one directive over: **if the slice is
not loaded, podman creates a transient slice of that name with no limits at all, silently.** Which
is why `agents.slice_limits` reads the limits back out of the cgroup and never out of the unit file.

**`--name` is not a DNS alias.** A gate run inside a namespace addresses its datastores by the bare
names its compose file uses - `db`, `redis`, `mailpit` - and a container started as `<id>-db`
answers to `<id>-db` and to nothing else. Without `--network-alias` every connection fails on a name
that does not resolve, in a namespace that never loads the file those names come from. The mirror of
the `torrent:<port>` lesson: a name proves one address and the unit files look identical either way.

**An environment variable that a config file uses VERBATIM is a different hazard from one it
derives.** `playwright.config.ts` falls back to a derived `E2E_REDIS_URL` on logical database **1**,
but uses an environment `REDIS_URL` exactly as given. Passing the dev URL - database 0 - collapses
the split that isolates the e2e suite from everything else, and every test still passes while doing
it. The runner passes `/1` explicitly, and `SMTP_HOST`/`SMTP_PORT` are the same family one variable
over: overriding only the host yields a name that resolves and a port that refuses.

**A safety guard that keys on "is the database on loopback" refuses inside a container namespace.**
upskald's `api/scripts/seed_demo.py` deliberately uses the narrow `LOCAL_DATABASE_HOSTS`
(`127.0.0.1`, `::1`, `localhost`) rather than the wider set that admits `db`, and its comment gives
the reason: *"This runs on the host, where the DSN `provision_database` resolves names a loopback
address, so it gains nothing from `db`."* **That premise is exactly what a phase runner breaks** -
the whole gate runs inside the namespace, so `db` is the address. Six tests fail with `assert 1 == 0`
and the refusal is only in captured stderr. Proved to be environment-specific rather than a broken
test: `database_is_local` returns `(True, '127.0.0.1')` for the workstation's URL under both sets,
and `(False, 'db')` under the narrow set for the runner's.


## The gate the fleet was going to trust, and six ways it was not a gate

- **RUNNING GIT IN A DIRECTORY IS RUNNING ITS OWNER'S CODE, AND TWO OF THE CALLS ALREADY SHIPPED.**
  A repository's own `.git/config` is executable surface and only three options are
  protected-config-only (`safe.directory`, `safe.bareRepository`, `uploadpack.packObjectsHook`).
  `core.fsmonitor` is a pathname git execs on any index refresh, so `git status` runs it;
  `core.hooksPath` and `.git/hooks/*` fire on checkout, commit and push; `diff.<driver>.textconv`
  fires on `git diff`; and `remote.<name>.url = ext::sh -c '<payload>'` fires on `git fetch`,
  because `protocol.ext.allow` defaults to `user` and a direct invocation leaves
  `GIT_PROTOCOL_FROM_USER` unset. The phase worktree is mounted `:rw` **including `.git`**, and
  `conduct`'s `prepare_worktree` runs `fetch --all` and `checkout --force` **as `core` on the host**
  - so a `--cap-drop=ALL --read-only` container on an isolated network with no podman socket was
  escapable by the routine whose purpose is not to trust that directory. **It needed no model
  phase**: `make install` runs `uv sync` and `bun install` against lockfiles the branch controls, one
  postinstall is enough, and because worktrees are reused it fires during a *later, unrelated* run
  with nothing in the log naming git. The fix is to remove `.git/hooks` and `.git/info` and rewrite
  `.git/config` from a template before the first git command; `git -c core.fsmonitor= -c ...` per
  call is whack-a-mole against an open-ended list where a miss is silent. Rewriting `config` also
  neutralises the tree-level half, since a `.gitattributes` naming `filter=evil` is inert once no
  `filter.evil.clean` is defined.
- **A DIFF IS ONLY AS TRUSTWORTHY AS THE REF IT IS MEASURED AGAINST.** `git merge-base HEAD
  origin/main` resolves `refs/remotes/origin/main` **in the worktree being inspected**, so one
  `git update-ref refs/remotes/origin/main HEAD` makes the merge-base equal HEAD, empties the diff
  and passes every protected-path check - with `git status --porcelain` clean throughout, because
  refs are not tree state. The first version of the gate-file check was defeated by a command that
  touches none of the files it inspects. Proved on the host: the worktree's own merge-base was
  forged to its HEAD and the refusal still landed, because the base is read from a bare repository
  only the orchestrator writes.
- **`git clone --local` HARDLINKS THE OBJECT STORE.** Measured: `stat` reports `links=2` on one
  inode reachable from both the mirror and the clone. With `.git` inside a writable bind mount, one
  `printf > .git/objects/pack/*.pack` inside a container corrupts the mirror every future clone -
  and every "pristine" verification tree - is built from, and it surfaces later, in an unrelated
  run, looking like a git bug rather than an attack. `--no-hardlinks` costs 13 MB here. The
  docstring that had to be corrected said the hardlinks "cost almost nothing", which was true and
  was the hole.
- **A RECEIPT ITS OWN SUBJECT CAN MINT IS NOT EVIDENCE.** `scripts/pr_quality_gate.py record` with
  no arguments writes `squash=done review=pass make_check=pass`, and nothing cross-checks those
  three strings against a run that happened. It is keyed to `head_sha` alone and never to the tree,
  so an edit after recording leaves it valid. The bypass hole everyone looks for is beside the
  point: an agent does not need to defeat that gate, it can satisfy it with one command the ship
  skill already tells it to run.
- **A HOOK WHOSE COMMAND CANNOT BE FOUND FAILS OPEN.** Measured against Claude Code 2.1.238, which
  the documentation does not cover: a `PreToolUse` hook supplied through `--settings` whose command
  does not exist lets the tool call **proceed**. So a hook can be a guardrail and never a boundary,
  and "python3 moved in the base image" or "the policy never got staged" produce a phase running
  unguarded that says nothing about it. Two things that ARE reliable, measured the same way:
  `--settings` hooks and project hooks both run on the same matcher, and a `deny` in `--settings`
  blocks a command project settings tried to allow. **`permissions.deny` spawns no process**, so it
  cannot fail this way and should carry any rule expressible as a pattern. A free property: the
  runner's `HOME` is ephemeral tmpfs, so a fleet worktree is never a *trusted* workspace and an
  untrusted workspace's `permissions.allow` entries are ignored outright - though its hooks still
  run, which is the asymmetry to remember.
- **A `PreToolUse` HOOK MUST NOT ANSWER `allow`, AND THAT IS NOT PEDANTRY.** An `allow` decision
  BYPASSES the permission system for that call, so a hook written to "allow what is fine and deny
  what is not" auto-approves everything the session does. The correct answer for a command with no
  rule against it is **silence** - print nothing, exit 0 - which defers to the normal flow.
- **UPSKALD'S CI TREATED `.claude/**` AS DOCS.** `scripts/path_filter.py` classifies it into an area
  that never feeds `shared`, and omits `scripts/pr_quality_gate.py` from `PIPELINE_CRITICAL_SCRIPTS`
  - so the pull request that guts the gate is the one CI barely runs. `make check` does not help:
  it never hashes, diffs or verifies any of the nine files that define the gate, and the only
  behavioural cover is a test file living on the same branch as the thing it tests.
- **`git reset --hard` DOES NOT MAKE A TREE PRISTINE.** It leaves untracked files, and
  `playwright-report/`, `test-results/`, `web/stats*.html` and `api/htmlcov` are all gitignored - so
  `git status --porcelain` never mentions them and the next run inherits the last one's output.
  `rm -rf .git` plus `git init`, a fetch, and `git clean -xdff` excluding only the dependency
  directories is what makes it pristine while keeping the fifteen minutes `make install` costs.
- **A PHASE THAT COMMITTED NOTHING PASSES EVERY OTHER CHECK.** The merge-base equals HEAD, the diff
  is empty, the tree is clean, and a human is asked to approve an empty pull request. `rev-list
  --count >= 1` is the only thing that catches it, and `merge-base --is-ancestor` is its sibling,
  for a phase that hands back unrelated history.
- **THE FILE THAT DECIDES WHAT A CHECK MEANS IS USUALLY NOT THE FILE A SHORT LIST NAMES.**
  `check-gate` is eight targets and almost every one leaves the Makefile immediately, so
  `web/package.json`'s `"lint": "eslint . --fix"` becoming `"true"` deletes a whole check while the
  Makefile - which is on every sensible protected list - never changes. But refusing on
  `api/pyproject.toml`, which carries ruff's ignore list and pytest's `filterwarnings`, would refuse
  most real work. Hence two tiers rather than one: a list that refuses, and a list that reaches the
  human. **And one class neither tier catches**: `check-gate` has no coverage step, so deleting a
  test is free and green, and no path list can express "fewer assertions than before".

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

## A filesystem that counts against the memory ceiling, and a browser that fills it

Diagnosed 2026-08-22, after `conduct verify` failed three times in a row and the first two readings
of it were both wrong.

- **A tmpfs inside a container is part of that container's MEMORY budget, not separate from it.**
  Its pages are charged to the cgroup that dirties them and, with no swap reachable, they cannot be
  reclaimed - so a full tmpfs pins `memory.current` at `MemoryHigh` and the kernel throttles the
  allocator instead of freeing anything. The runner mounted `/tmp` at **2g** and `/dev/shm` at
  **1g** under a `MemoryMax` of **3G**: the two filesystems could reach the hard limit between them
  with every process behaving perfectly. The sizing comment in `conduct/phase.py` had reasoned about
  exactly this hazard and then compared **one** filesystem against **MemoryMax**, when the test is
  the **sum** against **`MemoryHigh` minus the working set**.
- **`--shm-size` was inert, and `/dev/shm` reading zero is what proves it.** podman mounts
  `/dev/shm` `noexec`; Chromium's `GetShmemTempDir()` falls through to `GetTempDir()` when it needs
  an executable mapping, and `GetTempDir()` reads `$TMPDIR`. So the 1 GB it was given went unused
  across three full gate runs while it put **1,925 MB across 969 unlinked fds** into `/tmp` - which
  the invocation had mounted `exec` deliberately, because `noexec` there breaks uv's managed
  interpreters and node's temporary binaries. **The flag that made `/tmp` work is the flag that made
  Chromium prefer it.**
- **The failure was invisible to every signal this stack has.** `memory.events max` and `oom_kill`
  both stayed **0** for the whole run - `MemoryHigh` throttles, it does not kill - so no unit
  failed, no container went unhealthy, no check fired and no alert reached the phone. `cpu.stat`
  `nr_throttled` was **0**, which retired the CPU-starvation theory on a number. What the browser
  reported was `net::ERR_INSUFFICIENT_RESOURCES` on 88 and 101 Vite module requests, so the SPA
  never mounted and Playwright said **`element(s) not found`** - not "not visible". A page that
  renders late and a page that never renders produce different words, and the difference is the
  whole diagnosis.
- **`du` cannot see an unlinked file, and that is why two readings were wrong.** `df` reported
  2,047 MB used while `du -x -d2 /tmp` summed to 49 MB, because a deleted-but-open file has no
  directory entry. Only `df` and `/proc/<pid>/fd` can see it. Anything reasoning about container
  disk usage from `du` is reasoning about a different number.
- **A container is not memory-namespaced or CPU-namespaced, so everything inside sizes itself for
  the HOST.** `/proc/meminfo` shows 15.8 GB and `nproc` returns 12, while the cgroup grants 3 GB and
  four cores' worth of quota. Chromium sizes its shared-memory pools from
  `AmountOfPhysicalMemory()`, node and esbuild size their thread pools from `nproc`. This is not
  Chromium misbehaving and it is not fixable in the application - it is the reason the hosting side
  has to leave room, and the reason upskald's `playwright.config.ts` was deliberately **not**
  changed.
- **The fix made it faster, which no part of the diagnosis predicted.** With `TMPDIR` on a
  disk-backed bind mount the e2e leg went from 9.0-9.9 minutes to **4.7**, the whole gate from
  ~1,160 s to **888 s**, `/tmp` peaked at **17 MB** instead of 2,047, and Chromium held **38 MB** of
  shared memory instead of 1,925. The likely reading - offered as a reading, since it was not
  measured directly - is that most of that 1.9 GB was self-inflicted: with the cgroup pinned,
  Chromium could not evict its own discardable segments, so it kept allocating more. On disk the
  loop never starts.

## The mirror is not a cache, and the second key cannot go where the first one is

Built 2026-08-22, when PR #241 merged and the fleet could not see it: the mirror still read a commit
from two days earlier, and re-seeding it existed only as a hand step written down nowhere - standing
in front of every verification from that day on.

- **A phase container cannot simply clone the branch it needs, and the mirror is where that
  requirement was moved to.** Three reasons, and only the first is about credentials.
  `avanserv/upskald` is **private** and the runner may hold no GitHub credential in any form - not a
  token, not a `gh` login, not a `.netrc`, not a credential helper, asserted against the argv by
  `tests/test_phase.py` - so a container that clones from GitHub is a container holding a credential
  for GitHub. The **base of the diff has to come from a repository the phase cannot write**, so
  conduct needs a host-side copy whatever the container does; the copy is not avoidable, only
  duplicated. And **one host-side copy is what pins the base**: worktree and base come out of the
  same object store refreshed at one moment, where two independent clones straddle a push with
  nothing saying so. What was never load-bearing is the workstation, and that is the half that went.
- **A second deploy key must not be added to the existing `Host github.com` block**, and the failure
  if it is does not name the cause. `~/.ssh/config` pins that host to `~/.ssh/agents_deploy` with
  `IdentitiesOnly yes`, so a second `IdentityFile` either loses to it or races it - and **GitHub
  answers a valid key for the wrong repository with `repository not found`**, which reads as a typo
  in the remote URL. `conduct/mirror.py` passes `-F /dev/null -i <key> -o IdentitiesOnly=yes` and
  drops the config file from consideration entirely: ordering identities against it is not
  deterministic, and ignoring it is. Proved in all four directions - each key reaches its own
  repository and neither reaches the other.
- **Refreshing the mirror at verification time is the obvious improvement on a 72-hour refusal, and
  it is a bug.** `main` advancing after the phase branched makes `git merge-base --is-ancestor base
  head` fail, so a fresher base turns a good run into *"the phase handed back history that does not
  build on the base it was given"* - a refusal that names the phase for something the refresh did.
  The fetch goes in `prepare_worktree`, where it gives the phase a fresh base and lets verification
  measure against the same one.
- **A dispatch refreshes the mirror itself, and the base has to be PINNED at that moment or it moves
  under the finished run.** `prepare_worktree` fetches before it clones, so a phase never runs
  yesterday's code and the nightly timer is only a backstop. But `conduct verify` runs later and read
  the base **live** out of staging, which re-fetches from the mirror on every call - so the nightly
  timer, or any other phase's dispatch refresh, changed the base of a run that was already over. The
  narrowed diff is the quiet half; the loud half is that once `main` advances at all,
  `merge-base --is-ancestor` fails and a good run is refused with *"the phase handed back history
  that does not build on the base it was given"*, **naming the phase for what the refresh did**. The
  base is a column on the run row now, and a pin that no longer resolves - a force-push on the base
  branch - is reported rather than silently replaced.
- **`CREATE TABLE IF NOT EXISTS` does not add a column to a table that already exists**, and the
  failure is not at deploy time: the statement is a no-op, the column is silently absent, and the
  first `UPDATE` naming it raises inside a phase that has already run. Migrate by inspecting
  `pragma_table_info` rather than by catching the exception - "duplicate column name" and a real SQL
  error arrive as the same `OperationalError`.
- **A mirror that stopped fetching is indistinguishable from one nobody has pushed to.** Its refs
  are valid, every clone works, every phase runs, and the only thing that is wrong is that the diff
  a human approves is against a base GitHub moved past. `conduct/verify.py` refuses at 72h, which is
  the backstop and not the detector - by then three nightly fetches have failed silently.
  `agents.mirror_fresh` reads **`FETCH_HEAD`'s mtime**, which dates the *attempt* rather than the
  change, so "nothing moved upstream" does not read as "the timer stopped".
- **The two bare repositories stay two, and the reason survives the credential.** Three of the
  reasons `conduct/staging.py` gives for not reusing the mirror dissolve once conduct controls the
  refspec. A fourth does not: `git clone --local` copies **every** ref, and staging accumulates
  `refs/conduct/runs/<run-id>` for ever, so a single repository would hand each new worktree every
  prior phase's commits, growing without bound.

## The control plane's arrow, and three states that look alike in the journal

Built 2026-08-22 with the polling half of the orchestrator.

- **conduct polls Windmill and Windmill has no route to conduct, which is containment rather than
  style.** A host-side listener needs either a unix socket - the same `container_t -> unconfined_t :
  unix_stream_socket connectto` denial that stops any container reaching the podman socket - or a
  TCP port plus a firewalld hole `ucore.bu` can only add at first boot. Both spend real containment
  to give an internet-facing container an RPC that spawns `claude`. In `paths.ts` this shows up as
  `conduct` being a pseudo-node that may **never** appear as a `to`; there it reads as a modelling
  rule and it is the security property.
- **Work arrives as a suspended flow step, so the transport is the human gate's own mechanism** -
  and what is conduct's and what is a human's is decided by the **module id**, which comes from the
  flow definition in git rather than from a payload the step computed. **conduct answering an
  approval step would be conduct approving its own gate**, so the guard is asserted by a test that
  fails the moment it is removed, and proved live against a planted human gate that conduct left
  suspended and never once mentioned. Refusing costs nothing either, because a refused step simply
  stays suspended - so the cascade can stay as blunt as it is.
- **`jobs/queue/list` DECLARES `args` and `flow_status` and returns both null.** The OpenAPI
  describes `QueuedJob`'s type, not what that endpoint populates; the list is a lightweight
  projection. Discovery is therefore one call plus one `jobs_u/get` per suspended job, which is
  cheap only because the normal number of suspended jobs is zero. Reading the schema is not
  measuring the endpoint.
- **A `suspend` belongs to the module it PRECEDES, which is the reverse of the obvious reading.**
  The module carrying it reads `Success` once it has run and the module *after* it reads
  `WaitingForEvents` and is what `flow_status.step` points at. The first flow put conduct's name on
  the module declaring the wait, so conduct read the id of the module that was waiting, found a name
  it did not own, and skipped it - **no error, no log line, and a job that would have sat suspended
  for its full 24-hour timeout**. Match on the module type as well as the index: `step` alone names
  whichever module the flow is at, and only `WaitingForEvents` means somebody is being waited on.
- **A drift check that fires on every flow the server has ever stored is not a check.** Windmill
  resolves a dependency lock into each `rawscript` module, so comparing a deployed flow against git
  byte-for-byte never matches. Strip the generated keys **by name**: "git's keys must match and the
  server may add anything" would also accept a `retry:` or a `cache_ttl:` added in the UI, which is
  the drift the check exists for.
- **`agents.approvals_pending` counts conduct's steps as well as a human's**, and cannot tell them
  apart in SQL, because both are `suspend > 0` on the same mechanism. It is left counting both and
  the message says so: conduct claims its own within one 60s poll, so anything reaching the 12-hour
  threshold is genuinely stuck whoever it was waiting on.
- **The answer is written to the database before it is delivered, and the order is the whole point.**
  A phase that succeeded and then could not be reported is twenty minutes already spent;
  rediscovering the same suspended step next cycle spends it again. A row with a payload and no
  `resumed_at` means retry the **resume** and never the phase. A crash *during* a phase is the
  opposite case and needs nothing: no row was written, so the reconciler's existing path covers it.
- **Not-configured and configured-but-broken must differ, and here they are one variable apart.**
  An unset `WINDMILL_CONDUCT_TOKEN` **holds** the poll and leaves `last_ok_at` advancing, because a
  rollout in progress must not look like a fault. A **401** stalls the heartbeat, because a revoked
  token is a fleet that has stopped taking work while every container is healthy, every unit is
  active and nothing else would ever say so. Do not "fix" a 401 by clearing the value.
- **A flow is a row in Postgres the UI can edit with nothing in `git diff`** - the same shape
  `agents.worker_lanes` exists to watch. `serve` rewrites it from git at every start, so drift is
  self-healing rather than detected, which is why there is no `agents.flow_drift` check: nothing has
  to grade a difference it can simply undo.
- **The verify lane stopped being the semaphore when the arrow inverted.**
  `windmill-worker-verify` was built as the one-verify-at-a-time mechanism on a design where
  Windmill dispatched. Under polling, conduct's one-lease-per-project is the semaphore and a
  suspended step occupies no worker at all - so the lane is bookkeeping and spare capacity. The
  quadlet still reads as though it were a limit.

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

## Discovery: three ways to find nothing while everything is green

Audited on 2026-08-19, after "Sonarr and Radarr cannot find some of the requested media" and the
obvious question of whether to add indexers. **None of it was indexer coverage**, and adding
indexers would have made two of the three worse. The pool was 13 configured, 12 enabled, 9 actually
answering; four had never served a single query and were deleted.

- **MOST OF WHAT IS "MISSING" IS NOT RELEASED YET, and the field that says so is not the obvious
  one.** Sixteen of Radarr's twenty-one wanted films were `status=announced` - Avengers: Doomsday,
  The Legend of Zelda, a 2027 Narnia. **Do not filter on `isAvailable`**: every movie here carries
  `minimumAvailability: announced`, so `isAvailable` reads **true for all twenty-one**, a film two
  years from a cinema included. It answers "may Radarr grab this", not "does this exist", and the
  two coincide only by accident. `status`, plus `digitalRelease`/`physicalRelease` against now, is
  the honest test. Reporting one total would have read as twenty-one things going wrong; five is
  the real number, and the gap between the two counts is the only one worth looking at.
- **THE `[VO]` PROFILE FLOOR WAS UNREACHABLE, AND CLAUDE.md ASSERTED THE OPPOSITE.** That file
  said "a VO-only release scores ~50, so it is grabbable". Measured against profile 9:
  `Lang: Original` is worth **10**, not 50, and the whole scale is `Audio: Surround` 10,
  `Codec: x264` 10, `x265` 20, `AV1` 30, `Lang: Original` 10, `Lang: Original + French` 500.
  Against `minFormatScore: 30`, **Silent Hill: Revelation 3D returned 124 releases and approved
  ZERO**; the best-scoring non-3D candidate among them scored 20. Every rejection was profile-side,
  so more indexers would only have produced more releases to reject. `Lang: Original` is now **30**,
  which makes the documented intent true rather than loosening the profile: a release with
  identifiable original-language audio clears the bar alone, one with no language information at all
  (score 0) still does not. After the change: 2 approved at score 40. **A number quoted in prose is
  not a measurement** - this one was wrong for as long as the profile existed, and the symptom was
  indistinguishable from "no release exists".
- **A BACK-CATALOGUE TITLE IS SEARCHED ONCE, AT ADD TIME, AND NEVER AGAIN.** Neither application has
  a scheduled missing search; everything automatic afterwards is RSS sync, which only ever sees what
  an indexer published **recently** - `Reports found: 411, Reports grabbed: 0` against a series that
  ended in 2004. Sex and the City was added 2026-08-18 18:50 and had 0 of 94 episodes; an
  interactive search on S01E01 returned **three releases, all three approved**, Remux / Bluray /
  WEB-DL 1080p at 5-21 seeders. The releases were there the whole time and nothing asked twice.
  `bin/search-missing.py` on `home-server-search.timer` is the fix.
- **AND IT SEARCHED BY SEASON, WHICH WAS THE OBVIOUS ECONOMY AND RETURNED NOTHING.** One query
  instead of thirteen, against a Prowlarr that was already answering Sonarr with
  `429 TooManyRequests` - written as the first rule, and disproved by the first live run. All six
  seasons came back `Season search completed. 0 reports downloaded`, having processed 4 to 10
  releases each, **because a season query asks an indexer for a season PACK** and these trackers
  index a 1998 series one episode at a time. The identical episodes searched individually queued
  all twelve of season one inside the hour. Measured cost of doing it the working way: 12 episodes
  x 8 indexers = 96 queries in about seven minutes, **zero 429s and zero indexers backing off** -
  against the ~770 a day RSS sync already does unattended. **A cheaper query that returns nothing
  is not cheaper**, and the per-run cap is counted in episodes because an episode is what costs a
  query.
- **A STALLED DOWNLOAD BLOCKS EVERY ALTERNATIVE RELEASE, AND REPORTS ITSELF AS `downloading`.**
  Kaamelott: The First Chapter had sat at 5.5 GB remaining of a 29.8 GB remux since 2026-08-14,
  "stalled with no connections". Because the queued item already meets cutoff, Radarr refused all
  **49** candidates with `Quality for release in queue already meets cutoff` - including six at
  score 870 with 48 and 68 seeders. So the most effective way to be unable to find something is to
  already be failing to download it, and nothing in the queue view says so. `search.stalled_queue`
  now warns. **It is named and never cleared**: removing the item deletes a partial download, which
  is a person's decision and not a timer's.

## The publish path, and two ways a killed phase never came back

- **A REPORT IS A VALUE, NOT A STATUS.** A Windmill flow module whose body is `return report`
  succeeds whatever the report says, so a payload of `{"ok": false, "exit_code": 1}` is recorded as
  a **green flow** - nothing raises, `CompletedJob success=true`. A failed gate had looked like a
  successful run since the transport landed, and the live proof did not catch it because the gate it
  ran passed. Harmless at two modules; the moment a verification and an approval sit behind it, a
  failed phase flows into twenty minutes of verifying a tree that already lost and then asks a person
  to approve it. The module raises now - and raises rather than `stop_after_if`, because a stopped
  flow is recorded *successful* and a failed gate is not a success.
- **A PHASE KILLED MID-RUN WEDGED ITS OWN STEP FOR EVER, and the code's own comment denied it.**
  `poll.py` opens the `dispatch` row before it dispatches, so a SIGKILL leaves a row with a NULL
  payload: the retry pass skips it (no payload) and the discovery pass skips it (a row exists). The
  lease, the network, the containers and the tree are all reclaimed and **the flow step stays
  suspended for its full 24-hour timeout with nobody owning it**, while `agents.approvals_pending`
  blames a person at twelve hours. Being killed mid-phase is a **designed** path here - the reboot
  window escalates past its second refusal - so it was reachable every Sunday morning, and
  `state.py` said *"A crash DURING a phase is the opposite case and needs nothing: no row was
  written"*. A row was written. The reconciler clears it, bounded by `REAP_AFTER_SEC` so a live
  phase's row is never touched.
- **THE RESUME RETRY LOOP HAD NO PREFIX GUARD.** The rule that conduct never answers a human's gate
  lived at exactly one call site, on the discovery path; the retry loop resumed every unresumed row
  with no check on `module_id`. Nothing could put a human-gate row there, so it was safe by accident
  - and one plausible way to record a sent notification, a `dispatch` row keyed
  `(job_id, "publish_pr")`, would have made the next cycle **approve the gate and open the pull
  request**. The guard belongs to resuming, not to a call site, and the notice has its own table.
- **`main` IS NOT BRANCH PROTECTED and GitHub has no ref-scoped deploy key**, so nothing on the far
  side refuses a push to the default branch from a write-capable credential. The name check in
  `conduct/publish.py` is the entire boundary - which is why an empty branch prefix is refused
  outright (`startswith("")` is true of everything, so it would silently make the guard a no-op with
  every test still passing) and why the name goes through `git check-ref-format` rather than a second
  regex: `WORKTREE_RE` admits `.`, so `a..b` is a legal worktree id and an illegal ref component.
- **A BRANCH NAMED FOR A REUSED WORKTREE LETS A PULL REQUEST CHANGE UNDER AN APPROVAL.** Worktree
  ids are reused deliberately - they hold the `node_modules` that make the gate minutes - so
  `agents/<worktree>` would carry every run. Run N+1 force-pushes while run N's approval is still
  suspended, a person approves a card describing run N, and the pull request opens on N+1's commit,
  with every check passing. The head sha goes in the branch name: immutable, no `--force`, nothing
  to lease, and `Everything up-to-date` is the correct answer to verifying twice.
- **A DEPLOY KEY HAS NO REST SURFACE AND A `pull_requests:write` PAT HAS MORE THAN ITS NAME.** The
  key cannot open a pull request, comment or label at all, which makes half the credential split
  structural. The token is the other half and it includes **labels** and **reviews**, and a
  fine-grained PAT acts as *the user* rather than a Bot - so `auto-merge.yml`'s `sender.type != 'Bot'`
  guard does not exclude it and that token could arm auto-merge on its own pull request. Accepted and
  recorded; what protects it is that the flow is the only actor, not that the credential is
  incapable. The same honesty applies one level up: a workspace-**owner** token can read any variable
  and run any job, so the split contains tier 1 and accident, never a compromised conduct.
- **ntfy WOULD HAVE DELIVERED NOTHING IN FOUR DIFFERENT WAYS, all of them exiting 0.** It renders
  markdown in its **web app only** - the phone apps show the source; `X-Message` cannot carry a
  newline, so the body must be JSON; the default message limit is **4096 bytes** and an oversized one
  is refused with a 400 rather than truncated; and it caches for **12 hours** against a human gate
  that waits seven days, so **a once-ever notification is lost for ever** if the phone was off for
  thirteen. The notice repeats every six hours while the step is still suspended.
- **A HOST-SIDE PUBLISHER HAS TO COME IN THROUGH THE FRONT DOOR, AND THE HOURLY BATTERY NEVER LOOKS
  AT THAT ROUTE.** ntfy is on `net-metrics` and publishes no host port, and `routes.ntfy` lives
  behind `--routes`, which is opt-in - so DNS, DuckDNS, the WAN address, the router's hairpin and the
  ISP would all sit in the path of the fleet's only notification with nothing hourly measuring any of
  them. Forcing the connection to Caddy on this host keeps the URL, the TLS name and the certificate
  and deletes all of it: 28 ms against 178 ms, both 200. The edge in `paths.ts` is therefore
  `conduct -> internet` and **not** `conduct -> ntfy` - the direct route does not exist, and the lint
  cannot catch that lie because it short-circuits any edge touching a pseudo-node.
- **A PLANTED COMMIT CANNOT PROVE THE CHAIN.** `prepare_worktree` resolves `origin/<ref>` and does
  `checkout --force --detach` then `reset --hard`, so anything committed by hand is orphaned before
  the phase starts - the run reaches verification, refuses "the phase committed nothing", and proves
  only the refusal. A `probe` phase running `git commit --allow-empty` produces a real commit with no
  model call and no credential, an empty diff that flags nothing, and a gate that passes because the
  tree is identical to a known-green base.
- **THE BASE PIN READ THE REPOSITORY THE PHASE WAS NOT CLONED FROM, and it blamed the phase for
  other people's commits.** `dispatch` pinned with `staging.base(project)`, which defaults to the
  **staging** repository - and staging is only fetched from the mirror by `staging.ensure()`, which
  runs later, inside verify. So the pin captured staging's PRE-refresh state while the worktree had
  just been cloned from the freshly refreshed mirror. The diff is then measured from a base older
  than the one the phase branched from, and **every commit somebody else pushed in that window is
  attributed to the phase**. Found on the first end-to-end run of the publish path: a phase whose
  entire output was `git commit --allow-empty` was refused for touching `Makefile` and
  `e2e/playwright.config.ts`, neither of which it had gone near. **The other direction is the one
  nobody would have caught** - a stranger's changes on the approval card as the agent's work. The
  worktree is cloned from the mirror, so the mirror defines the base; verify still reads staging,
  because that is where the phase's commits were fetched to and where the diff is computed. Two
  callers, two repositories, which is what the argument is for.
- **THE ENCODER GATE REFUSED ON A DEVICE THE FLEET CANNOT ADDRESS.** A phase runner is given no
  `--device`, no CDI reference and no `--gpus`, so refusing to dispatch while a transcode ran was
  contention for hardware the fleet has no route to - while CPU, memory and IO, which do contend,
  are bounded by `app-agents.slice` and by `nice -n 10`/`CPUWeight=20`. **And it failed in
  aggregate**, the same way the reboot window's encoder veto did: defensible on every individual
  refusal, and because dispatch is CONTINUOUS, any transcode queue at all meant the fleet never
  started. Found on the first end-to-end run - four files queued, two mid-flight, and the first
  thing the poll loop said was that it was holding. Recorded now rather than gated on, which is what
  I/O pressure already gets. The reboot window's gate is untouched: killing a live transcode to
  apply an OS image is a real cost that deserves a real refusal.
- **A DRIFT CHECK CAN FIRE ON A KEY THE SERVER REFUSES TO KEEP.** Windmill does not store a suspend
  key whose value is its default, so sending `continue_on_disapprove_timeout: false` made
  `conduct flow --check` report DRIFTED for ever on a flow that was exactly right - git held a key
  the server had dropped. **The mirror image of the `lock` trap**: that one is the server ADDING what
  git did not send, stripped by name; this is the server DROPPING what git did send, and the fix is
  not to send it. Detection is unharmed, because a UI edit setting it to `true` is not the default
  and therefore IS stored. Caught on the first deploy of the flow, the only run where it would have
  been obvious rather than ambient.
- **A FOLDER PATH IN WINDMILL IS A STRING, NOT A REFERENCE.** `f/agents/phase` deployed happily into
  a folder that does not exist, so a secret placed under the same path would carry no folder ACL.
- **`render-template.py` EXITS ON AN UNSET VARIABLE**, so adding one to `apps/ntfy/server.yml` makes
  ntfy refuse to start until `.env` carries it - and ntfy is the alert path, so that failure cannot
  page you about itself. `sops` and the push have to land before the server renders, which is the
  order CLAUDE.md's secrets block already gives; the hazard is restarting ntfy after a `git pull` and
  before `./bin/render-env.sh`.
- **DRAFT PULL REQUESTS ARE A PAID-PLAN FEATURE ON PRIVATE REPOSITORIES**, and none of a repository's
  merged pull requests proves the plan allows them - `avanserv` is on `team`, checked. Opening as a
  draft is the right posture anyway: `ai-review` is the **only** draft-gated job in `ci.yml`, so a
  draft gets the whole pipeline without a robot reviewing a robot, and auto-merge cannot arm on it.
  Note that `CI Passed` counts a skipped job as a pass.

## A restart that cut a stream, and the gate that was looking at the wrong device

- **THE NIGHTLY CONTAINER UPDATE INTERRUPTED A LIVE JELLYFIN SESSION, and the series recorded the
  whole thing.** `podman-auto-update` runs at ~00:00 UTC and Jellyfin follows `:latest`, so it is
  recreated whenever the image moves. On 2026-08-19 that was 00:20:30. Reading
  `sum(home_server_jellyfin_sessions)` and `home_server_jellyfin_sessions_total` at one-minute
  resolution: `playing=1 total=3` steady from 00:10 to 00:20, **no sample at all at 00:21** because
  the collector could not reach a container that was down, `playing=0 total=0` at 00:22, then
  `playing=1 total=1` from 00:23 onward. One client resumed; the other two never came back. It is
  the ONLY night in ten that Jellyfin's image actually moved, which is what makes this worth a gate
  rather than a reschedule - the exposure is roughly weekly, and moving the hour changes the odds
  without removing them.
- **`podman auto-update` HAS NO PER-CONTAINER FILTER.** podman 5.8.4 offers `--authfile`,
  `--dry-run`, `--format`, `--rollback` and `--tls-verify`, and nothing else - so "update everything
  except Jellyfin" is not a thing that can be asked for. Dropping `AutoUpdate=` from the quadlet is
  not the same request: it turns Jellyfin's updates off permanently rather than conditionally, gives
  up podman's rollback (which `Notify=healthy` exists to arm), and trips `update.policy_count`,
  which derives both sides of its count from the same authority and FAILs on a mismatch. So the
  whole run is gated, which costs nothing: nothing here needs an image on the night it ships.
- **`ExecCondition=` IS THE PRIMITIVE, NOT `ExecStartPre=`.** A non-zero `ExecStartPre=` FAILS the
  unit; a non-zero `ExecCondition=` (1-254) SKIPS it and leaves it not failed, while 255 or a signal
  still fails. That is exactly the property `bin/reboot-when-staged.sh` gets from `refuse()` exiting
  0, and it is why `bin/update-when-idle.sh` exits **1** to refuse - the one place the two scripts
  invert. A deferral that marked the unit red would be a night when everything worked correctly and
  the host reported a fault.
- **THE REBOOT WINDOW HAD THE SAME HOLE FROM A DIFFERENT DIRECTION, and the existing gate could not
  see it.** `bin/reboot-when-staged.sh` asked `nvidia-smi --query-gpu=utilization.encoder`, which is
  a perfectly good question about transcoding and says nothing about playback: **a DirectPlay
  session hands the file to the client untouched and opens no encode session at all**, so the
  encoder reads 0% while a film is playing. Measured on this host. For as long as that section was
  one gate, the Sunday 05:00-09:00 window could cut a stream with every check passing.
- **THE SAME MEASUREMENT IS PRICED TWO WAYS ON PURPOSE, and getting this backwards is the trap.**
  `bin/jellyfin-watching.sh` exits 2 for "running but unaskable". The reboot gate treats that as a
  refusal, because unknown is not idle and the cost of a wrong reboot is a car journey. The update
  gate treats it as go, because failing closed there means a broken Jellyfin API silently stops all
  twenty-seven containers updating while every unit reads healthy - the "host stops taking updates
  and nothing says so" failure arriving from yet another direction. `update.playback_probe` is what
  keeps the open direction from being a blind spot. A container that is NOT RUNNING is 0 rather than
  unknown in both, since there is no session to interrupt in one that is already down.
- **A STALENESS FILTER AND A CEILING CATCH DIFFERENT THINGS, AND BOTH ARE NEEDED.** A client that
  vanishes without telling the server lingers in `/Sessions` with a frozen `LastPlaybackCheckIn`, so
  a session counts only if it checked in within 300s. That drops ghosts and does nothing at all
  about the case the data actually shows: **one unbroken run of 18.4 hours**, which a browser tab
  left open on a paused episode sustains with perfectly fresh check-ins. Only the 3-day ceiling
  breaks that. Three days rather than the encoder's fourteen because the trade is priced
  differently - a dropped stream costs about fifteen seconds with the position already saved, where
  a killed transcode costs an hour of GPU time.
- **THE HOST IS ON UTC AND THE HOUSEHOLD IS NOT**, which makes every `OnCalendar=` in
  `host/systemd/` easy to read wrongly. `timedatectl` reports UTC, so podman's stock `OnCalendar=daily`
  was already firing at 02:00 local rather than midnight, and "move it to 5am" would have landed it
  at 03:00 UTC - exactly on `home-server-backup`, restarting containers underneath restic, which is
  the partial-snapshot-and-a-lock condition `reboot-when-staged.sh` already refuses over. The window
  is 00:00/01:00/02:00 UTC: three attempts, the quietest band in the session series, and stopping
  one hour short of the backup.
- **THE SYMLINK LOOP GLOBS BY EXTENSION, AND THIS IS THE THIRD TIME THAT HAS COST SOMETHING.**
  `host/systemd/README.md` linked `*.service.d` only, so the first `*.timer.d` in this repository
  was invisible: `daemon-reload` succeeded, `systemctl cat` showed podman's stock timer, and the
  retry window did not exist. Same shape as the `Slice=` entry above. The glob now covers both, and
  an existing host needs the link made by hand once.
