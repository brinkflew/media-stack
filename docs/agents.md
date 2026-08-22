# The agent fleet

`conduct`, the orchestrator for the autonomous coding-agent pipeline, and everything on this host
that it runs on. Written 2026-08-20, when the orchestrator first ran a real gate.

The orchestrator's own code is in `brinkflew/agents`, deployed to `/var/agents`. **This file is the
hosting**: what it runs as, what it may reach, what it writes, and the decisions that are easy to
reverse by accident.

## Three tiers, and each one is defined by what SELinux lets it reach

```
tier 0  systemd --user, unconfined_t   home-server-conduct.service   may fork podman
tier 1  container_t, uid0 -> core      conduct-runner (--rm)         the gate, and later `claude -p`
tier 2  container_t, uid0 -> core      db / redis / mailpit          stock images, no bind mounts
        container_t, uid0 -> core      windmill-{db,server,worker}   the control plane
```

**No container here may reach the podman socket**, and that single fact produces most of this
design. `container_t -> unconfined_t : unix_stream_socket connectto` is DENY under enforcing
SELinux, and it is not fixable by relabelling, because `systemd --user` for uid 1000 runs as
`unconfined_t`. The dashboard is read-only for the same reason and says so in its own unit.

Forking podman is the entirety of conduct's job, so conduct runs where the socket is: a plain
`systemd --user` unit, the `bin/collect-metrics.py` pattern, reaching services that are deliberately
unable to reach each other. **It never evaluates model output.** Everything an agent can influence
happens in tier 1.

**The arrow to Windmill is inverted for the same reason.** A host-side listener would need either a
unix socket - the same denial - or a TCP port on the bridge gateway plus a firewalld hole that
`host/butane/ucore.bu` can only add at first boot. Both spend real security to give an
internet-facing container an RPC that spawns `claude`. So `windmill-server` publishes on
`127.0.0.1:${PORT_WINDMILL_HTTP}` and **conduct polls it**. Windmill has no route to the host at all.

## What travels to the phone, and what must never

**A resume URL must never leave this host in a notification.** `ntfy.{$DOMAIN}` is deliberately
outside sign-on, because a phone app has no browser in which to complete a passkey prompt - see
`docs/networking.md`. Windmill's `jobs_u/resume/{id}/{resume_id}/{signature}` carries an HMAC
signature in the path and needs no session, so a signed resume URL in an ntfy message would make
**the ntfy credential sufficient to approve an agent's merge**.

**What travels is the link to Windmill's own approval page**, at `agents.{$DOMAIN}`, which is behind
`import protected` and therefore behind the passkey prompt. The cost is that a Pocket ID outage
blocks approvals, and that is the correct direction: an autonomous agent whose gatekeeper is down
should fail closed.

**conduct itself never needs a signed URL either**, which was found by reading the OpenAPI document
rather than assumed: `POST /w/{workspace}/jobs/flow/resume/{id}` - *"resume a job for a suspended
flow as an owner"* - resumes with an ordinary API token. An earlier note in this build recorded that
no authenticated resume endpoint existed; that was a grep that looked under `jobs_u` and at
`jobs/resume_urls` and missed the path carrying neither spelling.

## Deployment: two checkouts and one mirror, none of them alike

| What | Where | How it gets there |
|---|---|---|
| this repository | `/var/home-server` | `git pull`, anonymous HTTPS - it is public |
| conduct | `/var/agents` | `git pull` over a **read-only deploy key**, nightly at 04:50 |
| the upskald mirror | `cache/conduct/mirrors/upskald.git` | `conduct mirror`, nightly at 04:40, over a **second** read-only deploy key |

**Two GitHub credentials on this host, both read-only, both scoped to one repository**, and neither
of them ever enters a container. `~/.ssh/agents_deploy` fetches `brinkflew/agents` into
`/var/agents`; `~/.ssh/upskald_deploy` fetches `avanserv/upskald` into the mirror.

**The mirror is not a cache, and deleting it does not simplify anything.** The obvious
simplification is to let each phase container clone the one branch it needs when it starts. Three
things stop that, and only the first is about credentials:

- **`avanserv/upskald` is private and the runner may hold no GitHub credential in any form** - not a
  token, not a `gh` login, not a `.netrc`, not a credential helper, asserted against the argv by
  `tests/test_phase.py`. A container that clones from GitHub is a container holding a credential for
  GitHub. The mirror is where that requirement was moved to the host side.
- **The base of the diff has to come from a repository the phase cannot write.** Even if the
  container could clone, conduct would still need its own host-side copy to measure against, so the
  copy is not avoidable - only duplicated.
- **One host-side copy is what pins the base.** Worktree and base come out of the same object store
  refreshed at one moment, so the sha a human approves is the sha the gate ran against. Two
  independent clones straddle a push and nothing says so.

**What was never load-bearing is the workstation.** Until 2026-08-22 the mirror arrived by rsync,
because the host had no key for that repository - and the consequence was that re-seeding it stood
in front of every verification as a step written down nowhere. The key removes that; the three
reasons above are untouched.

**`-F /dev/null`, not a second `~/.ssh/config` block, and it is the one mechanical trap here.**
That file pins `Host github.com` to `agents_deploy` with `IdentitiesOnly yes`, so a second key added
the obvious way either loses to that block or races it - and **GitHub answers a valid key for the
wrong repository with `repository not found`**, which reads as a typo in the remote URL rather than
as the wrong identity. Dropping the config file from consideration is deterministic; ordering
identities against it is not.

**The refresh runs at `prepare_worktree` and deliberately NOT inside `verify`.** Refreshing at
verification time looks like the obvious improvement on a 72-hour refusal and is a bug: `main`
advancing after the phase branched makes `merge-base --is-ancestor base head` fail, so a fresher
base turns a good run into *"the phase handed back history that does not build on the base it was
given"*. `conduct/verify.py`'s 72-hour refusal stays as the backstop for the timer having stopped,
and `agents.mirror_fresh` is the detector in front of it - a mirror that quietly stopped fetching is
indistinguishable from one nobody has pushed to, so it reads `FETCH_HEAD`'s mtime, which the fetch
writes for free.

**Two bare repositories, and they stay two.** `mirrors/` holds upstream refs; `staging/` holds
`refs/conduct/runs/<run-id>` and is the only thing conduct pushes into. Collapsing them once conduct
controls the refspec is tempting and the three reasons in `conduct/staging.py` do dissolve - but a
fourth does not: `git clone --local` copies **every** ref, so one repository would hand every future
worktree every prior phase's commits, growing without bound.

**The mirror lives under the fleet root because of SELinux.** `chcon -R -t container_file_t` was
applied to `cache/conduct` once and new files inherit the type from their parent, so an rsynced
mirror and every worktree cloned from it come out readable by a container at no per-start cost.
Anywhere else under `/var` is `var_t` and every phase fails with a permission error naming SELinux
nowhere. **The label is not durable** - a `restorecon -R /var` or a relabelling reboot silently
resets it - and `agents.fleet_root_label` is the only thing that would say so.

**conduct is stdlib-only and has no virtualenv**, which is a constraint rather than a preference.
`/usr` here is read-only, every layered package makes the next rebase slower and able to fail on
dependency solving, and there is no `uv` on this host. `bin/collect-metrics.py`,
`bin/search-missing.py` and `bin/promote-transcoded.py` all hold the same line. It also keeps
`agents.checkout_drift` honest: that check counts **untracked** files, so a `.venv` in `/var/agents`
would be a permanent WARN whose message - *"the orchestrator running is not the orchestrator in
git"* - would be false.

## A phase, and the negatives that are the containment

```
podman network create --opt isolate=true net-conduct-<id>
podman run -d <id>-{db,redis,mailpit}    --network-alias db|redis|mailpit
                                          --no-healthcheck  --label io.home-server.ephemeral
                                          --cgroup-parent=app-agents.slice
git clone --local --no-hardlinks mirrors/<project>.git worktrees/<id>
systemd-run --user --scope --collect --slice=app-agents.slice -p MemoryMax=3G -p TasksMax=1024
            -p RuntimeMaxSec=5400 -- nice -n 10 podman run --rm --cgroups=split --cap-drop=ALL
            --read-only --network net-conduct-<id> ... conduct-runner:latest
```

Five of those are not obvious, and each was measured rather than reasoned about:

- **`--network-alias`, not just `--name`.** The gate addresses its datastores by the bare names its
  compose file uses. A container named `<id>-db` answers to `<id>-db` and to nothing else, so
  without the alias every connection fails on a name that does not resolve, in a namespace that
  never loads the file those names come from.
- **`--no-healthcheck` is the cheapest containment here.** Three checks read the health *state* of
  whatever `podman ps` returns, and each misreads a fleet container that inherited a healthcheck
  from its base image: `containers.healthy` FAILs, which blocks `bin/reboot-host.sh` and so stops an
  OS security update; `containers.probe_binaries` WARNs and pages; `logs.healthcheck_events` reports
  a setting in force as not in force. One flag closes all three at the source. Readiness is asked
  for with `podman exec` instead - which also keeps these out of `home_server_container_health`
  entirely, so the critical `ContainerUnhealthy` rule cannot page for a throwaway. **Do not add
  `--health-cmd`.**
- **`--cgroups=split` for the runner, `--cgroup-parent` for the datastores**, and they are not
  interchangeable. Measured from `/proc/<pid>/cgroup`: the runner reaches `app-agents.slice` through
  its transient scope, but a detached `podman run` lands in `user.slice/libpod-<id>.scope`, outside
  the ceiling entirely. An aggregate limit with three unaccounted members underneath it is worth
  having only if it says so.
- **`nice -n 10` in front of podman, never `-p Nice=`.** `Nice=` is an exec-context property and a
  `--scope` is not started by systemd, so `systemd-run` refuses the *whole invocation* with
  `Unknown assignment: Nice=10`.
- **The runner's ceiling binds before the slice's.** 3G under the slice's 4,608M, because a cgroup
  OOM picks its victim by badness across the whole subtree and rootless podman refuses to lower the
  Windmill workers' `oom_score_adj` - so with the slice binding first the kill could land on a
  worker mid-job rather than on the phase that caused it.
- **`$TMPDIR` is a disk-backed bind mount and must never go back to being a tmpfs.** This entry
  used to read *"`/tmp` is sized below the memory ceiling for the same class of reason: tmpfs pages
  are charged to the cgroup, so a larger `/tmp` turns 'No space left on device' into an OOM kill
  that names nothing."* The mechanism is right; the arithmetic was wrong twice, and on 2026-08-22 it
  cost three full gate runs. It compared **one** filesystem against **MemoryMax**, when the tmpfs
  and the processes draw on **one** budget - so the comparison is against `MemoryHigh` minus the
  working set - and there are **two** tmpfs mounts, because `--shm-size` is one as well. 2g of
  `/tmp` plus 1g of `/dev/shm` was 3G of filesystem inside a 3G hard limit.
  **What that produced was quieter than the OOM kill it was avoiding**, which is the part worth
  remembering: `/tmp` is now `512m`, `TMPDIR=/scratch` is a per-run bind mount under the fleet root,
  and `bin/conduct-runner-smoke.sh` asserts the property by **filesystem type**, because a later
  simplification back to a tmpfs would keep the path and lose the point.

**What is absent is the containment**, and the list stays negative: no podman socket, no
`--privileged`, no `--security-opt label=disable`, no mount from `config/` or `/mnt/media`, and for
the `check` phase no credential of any kind - it makes no model call, so there is nothing to hand
it.

**`--security-opt label=level:s0` is NOT here and must not be added.** The premise for it was that
files in a bind mount inherit the creating container's MCS categories, so a second run gets EACCES
on what the first wrote. Measured over four containers: every file came out `container_file_t:s0`
with no categories. The categories come from `:Z`, which this design does not use. The flag would
have removed per-container MCS separation for nothing.

## The gate is not evidence, and everything else here follows from that

`upskald` carries a PR quality gate: a `PreToolUse` hook that denies `gh pr create`
unless a receipt keyed to HEAD records squash, review and `make check` as passing.
It was going to be most of the fleet's containment. **It cannot be any of it**, and
the reasons are worth stating in order because each one is invisible from the
next.

**`record` mints its own receipt.** `python3 scripts/pr_quality_gate.py record`
with no arguments writes `squash=done review=pass make_check=pass`, and nothing
anywhere cross-checks those three strings against a run that happened. It is keyed
to `head_sha` alone and never to the tree, so an edit after recording leaves it
valid. An agent does not need to defeat the gate; it can satisfy it, with one
command the ship skill already tells it to run.

**A hook fails open.** Measured against Claude Code 2.1.238, which the
documentation does not cover: a hook supplied through `--settings` whose command
does not exist lets the tool call **proceed**. So anything able to stop the hook
being found has already beaten it, and a hook can be a guardrail but never a
boundary.

**And the gate is files on the branch.** `.claude/settings.json`, the hook shim
and `scripts/pr_quality_gate.py` are all tracked, inside the writable mount, and
`make check` never looks at them. Hooks also hot-reload from disk, so the
project's own gate can be disarmed mid-session with nothing ever committed.

**So conduct believes nothing the phase produced** - not the receipt, which is
deleted rather than read, not the exit code it reports, not the gate it says it
ran. `conduct verify` runs on the host afterwards, and the gate is re-run on a
tree built from a repository the phase could not reach.

### Running git in the worktree is running the phase's code

**The sharpest finding in this design, and it applies to two calls that shipped
before any model phase existed.** A git repository's own configuration is
executable surface, and only three options are protected-config-only
(`safe.directory`, `safe.bareRepository`, `uploadpack.packObjectsHook`):

| Option | Executes on |
|---|---|
| `core.fsmonitor` | any index refresh, so `git status` |
| `core.hooksPath`, `.git/hooks/*` | checkout, commit, push |
| `diff.<driver>.textconv` | `git diff`, named from `.gitattributes` |
| `remote.<name>.url = ext::sh -c` | `git fetch` |

The worktree is mounted `:rw` **including `.git`**, so a phase can write all of
those - and `prepare_worktree` then runs `git fetch --all` and
`git checkout --force` **as `core`, on the host, outside every cgroup, network and
SELinux boundary this design has**. It does not need a model phase to reach:
`make install` runs `uv sync` and `bun install` against lockfiles the branch
controls, one postinstall is enough, and because worktrees are reused it fires
during a *later, unrelated* run with nothing in the log naming git.

`conduct/gitsafe.py` removes `.git/hooks` and `.git/info` and rewrites
`.git/config` from a template before the first git command of every run.
Rewriting the file is bounded; `git -c core.fsmonitor= -c ...` on each call is
whack-a-mole against an open-ended list where missing one entry is silent. It
also neutralises the tree-level half for free, since a `.gitattributes` naming
`filter=evil` is inert once no `filter.evil.clean` is defined.

### A diff is only as trustworthy as the ref it is measured against

`git merge-base HEAD origin/main` resolves `refs/remotes/origin/main` **in the
phase worktree**. One `git update-ref refs/remotes/origin/main HEAD` makes the
merge-base equal HEAD, empties the diff and passes every protected-path check -
while `git status` stays perfectly clean throughout, because refs are not tree
state. The first draft of the gate-file check was defeated by a command that
touched none of the files it inspects.

So the base is read from `cache/conduct/staging/<project>.git`, a bare repository
**only conduct writes**, refreshed from the mirror on every verification. Not the
mirror itself, for three reasons: it was made with `git clone --mirror`, so its
refspec is `+refs/*:refs/*` and any refresh - including the `rsync` that seeds it
- prunes anything conduct put there; a per-run ref outside `refs/heads/` also
stops `clone --local` propagating `origin/conduct/*` into every future worktree;
and making the one durable artifact on the host writable by the verification path
is the wrong direction.

### `git clone --local` hardlinks, and `git reset --hard` does not clean

Two more measured rather than reasoned about. **The clone shares inodes** -
`stat` reports `links=2` on one object file reachable from both the mirror and
the worktree - so without `--no-hardlinks` a single write inside a runner
corrupts the mirror every future worktree and every "pristine" verification tree
is built from, surfacing later as what looks like a git bug. The mirror is 13 MB.
**And `reset --hard` leaves untracked files**, of which `playwright-report/`,
`test-results/`, `web/stats*.html` and `api/htmlcov` are all gitignored - so
`git status --porcelain` never mentions them and a "clean" tree is not clean. The
verification tree is rebuilt with `rm -rf .git`, `git init`, a fetch from
staging, and `git clean -xdff` excluding only the dependency directories.

### What verify does, in order, and why the order is the design

```
0  sanitize   .git/hooks and .git/info removed, .git/config rewritten
1  clean      status --porcelain=v1 -uall, rc 0 AND empty, no rebase in progress
2  extract    fetch HEAD into staging under refs/conduct/runs/<id>, fsckObjects
              base read from staging, never from the worktree
3  sanity     base is an ancestor of head, and head is at least one commit ahead
4  diff       REFUSE refuses; FLAG and deleted tests reach the approval card
5  pristine   a tree built from staging, gate run there, THEN assert it is clean
6  publish    conduct pushes (contents:write); Windmill opens the PR after approval
```

**Step 1 exists because a phase that committed nothing passes everything else** -
the merge-base equals HEAD, the diff is empty, the tree is clean, and a human is
asked to approve an empty pull request. **Step 5's second clean check is worth
more than step 1's**: `check-gate` runs `format` and `lint` before anything that
only reads, `api/pyproject.toml` sets `[tool.ruff] fix = true` and both frontend
`lint` scripts are `eslint . --fix`, so a tree dirty *after* a passing gate is a
tree whose committed form is not the form that passed.

**And the phase does not run the full gate at all.** `ship` runs
`make lint type-check unit-test` to iterate; the one full run happens in the
pristine tree. That is not an economy - the phase-side gate attests nothing,
because the tree can lie, the *meaning* of `make check` is agent-controlled
through `web/package.json`, and the receipt is mintable. The phase runs checks to
iterate; verify runs them to produce evidence, and **nothing the phase reports is
read by verify**.

### Two tiers of protected path, because one would refuse every real change

`check-gate` is eight targets and almost every one leaves the Makefile
immediately. So `web/package.json`'s `"lint": "eslint . --fix"` becoming `"true"`
deletes a whole check while the Makefile - which *is* on the short list - never
changes. But refusing on `api/pyproject.toml`, which carries ruff's ignore list
and pytest's `filterwarnings`, would refuse most real work.

`REFUSE` stops a run: `.claude/**`, `.github/**`, `Makefile`, the gate script and
its test, `path_filter.py`, `playwright.config.ts`. **`FLAG` reaches the human**:
the package manifests, `pyproject.toml`, the tool configs, the lockfiles,
`scripts/**`. So does a **deleted test**, which no path list can express because
`check-gate` has no coverage step - deleting a failing test is free and green.

### The hook, and being honest about what it buys

`conduct/hooks/deny.py` is copied into the fleet root at dispatch, mounted
read-only at `/opt/conduct`, and named by an inline `--settings` payload
alongside a `permissions.deny` list. Three things were measured before it was
written, because the documentation is ambiguous on all three: **a `--settings`
hook and a project hook both run** on the same matcher; **a `deny` in
`--settings` blocks** a command the project settings tried to allow; and **a
missing hook command fails open**, which is why none of this is the boundary.

`permissions.deny` is the stronger half and should carry any rule expressible as
a pattern, because **it spawns no process and so cannot fail open**. The hook
covers what a pattern cannot - `PR_GATE_BYPASS` anywhere in a command, a nested
`claude` (a child process has no hooks), a write verb aimed at a `REFUSE` path.

**The Bash path rule is blunt on purpose, and it costs a false positive.** It refuses any command
*naming* a `REFUSE` path rather than trying to recognise the ones that write, because enumerating
write verbs is a losing game - `cp`, `mv`, `dd of=`, `ed`, `patch`, `git apply`, `awk -i inplace`
and `rm`, which is not a write at all - while enumerating the paths is a closed set. So `cat
Makefile` is refused. That is deliberate and should not be "fixed" by loosening the rule: reading
those files through the Read tool is unaffected, and the message says which path and why.

**It is defeated by one level of indirection and that is accepted.**
`base64 -d > /tmp/x.sh; bash /tmp/x.sh` contains no protected path and no
suspicious verb, and neither does a `package.json` script or a `conftest.py`. It
is there for drift and for the model doing the obvious thing after reading a
skill file that hands it the bypass string - which `ship/SKILL.md`, `pr/SKILL.md`
and the gate's own deny message all do. Two consequences: **verify must never
read anything the hook produced**, or the weaker layer becomes load-bearing; and
the residual - a deleted test, a `# noqa` spree, a lockfile bump - **is the
approval card's problem**, which is why `FLAG` exists at all.

**A property worth not breaking**: the runner's `HOME` is an ephemeral tmpfs, so
a fleet worktree is never a *trusted* workspace, and an untrusted workspace's
`permissions.allow` entries are ignored outright. The branch cannot widen its own
permissions even before any of this applies. Its hooks do still run, which is the
asymmetry to remember.

**The mount is asserted before any work.** `sha256sum -c /opt/conduct/SHA256SUMS`
runs ahead of the phase command and exits 78 if the policy did not arrive,
arrived stale, or arrived truncated - because the failure it would otherwise
produce is no failure at all.

### The GitHub credential is two credentials, and the runner holds neither

conduct holds `contents:write` from `.env` and pushes the verified branch.
**Windmill holds `pull_requests:write` as a workspace secret**, used by the flow
step that runs *after* the human approval gate. So opening a pull request
requires the approval structurally, rather than requiring conduct to have
honoured it, and deleting one variable in a browser stops the fleet opening pull
requests while leaving everything else running. `windmill-worker` on `net-agents`
reaches `api.github.com` - measured, 200 in 112 ms - which is what makes the
split possible at all.

**Nothing else follows that secret into Windmill.** No policy, no protected-path
list, no gate configuration: `agents.worker_lanes` exists because a worker's tags
hot-reload from a row in that same database that the UI can edit with nothing in
`git diff`, and a security policy has exactly that shape.

## Placement: conduct must put itself in the slice

`home-server-conduct.service` carries `Slice=app-agents.slice`, so a phase the unit dispatches is
bounded. **A hand-run `conduct run` inherits the caller's cgroup** - started over ssh that is
`session-N.scope` under `user.slice` - so conduct and every podman helper it forks were bounded by
nothing, while the slice measured only the phase scope inside them. Every phase run during step 11's
verification was outside the ceiling in exactly that way.

**A process cannot simply be moved in.** Under cgroup v2 an internal node may not hold processes and
`app-agents.slice` always has children, so writing a pid into its `cgroup.procs` is not available.
`conduct run` and `conduct serve` therefore **re-exec themselves** through
`systemd-run --user --scope --collect --slice=app-agents.slice`, carrying the same
`MemoryHigh=384M`/`MemoryMax=512M` the unit does - identical rather than approximately alike. The
check is `/proc/self/cgroup`, which asserts the effect rather than a flag.

It **fails closed only where it can succeed**: if the slice has a unit file and the re-exec cannot
happen, `run` refuses; if the slice does not exist this is not the fleet host, so it warns and
continues. Refusing everywhere else would make the tool unusable on a workstation.

## The refusal cascade, and the four things that make it wrong if written the obvious way

`conduct` refuses to dispatch while the host is busy, over twelve units across **both** managers.
`conduct doctor` resolves the whole list and exits non-zero when it has drifted.

- **It has to ask the system manager too.** The cascade asked `systemctl --user` only and was blind
  to every system unit - including `rpm-ostreed-automatic`, which pulls multi-gigabyte layers and
  calls `syncfs`, and `raid-check`, a full array scrub. Neither was in any watchlist on this host,
  and staging a deployment is what the machine was doing when it stalled on 2026-08-20.
  `systemctl show` on a system unit needs no sudo.
- **A missing unit reads as idle, not as an error**, so a misspelt entry is a gate that can never
  fire. `LoadState` comes back in the same round trip and `not-found` is treated as a fault in the
  LIST. **Faults are reported and never refused on** - a wrong name must be loud without wedging the
  fleet, which would trade a blind gate for a stuck one.
- **`rpm-ostreed.service` must never be polled.** `rpm-ostree status` D-Bus-activates it, so a
  cascade watching that unit flips itself to busy on its own first poll. The `transaction` field is
  asked instead.
- **`podman-auto-update` exists as both a system and a user unit here**, and only the user timer is
  scheduled - so watching the system copy alone reads inactive for ever while images are pulled.
  Both are watched.

**I/O pressure is recorded and not gated on.** `/proc/pressure/io` is printed at dispatch and at
exit. The 2026-08-20 outage was an I/O stall so a threshold is the obvious next move, and it would
be invented: nothing here has a baseline for this host's normal. `app-agents.slice` carried exactly
that admission about `TasksMax` until a real gate run measured it at 325.

## The marker, and why it is not in `backup-state`

conduct writes `~/.cache/home-server/conduct-state`, flat `key=value`, in the shape of
`backup-state` and `metrics-state`. Twelve checks in `bin/verify-host.sh`, twenty-two series in
`bin/collect-metrics.py` and one refusal in `bin/reboot-when-staged.sh` read it.

**It is its own file rather than a section of `backup-state`, and the reason is invisible until
somebody tidies the two together**: `bin/backup-server.sh` rewrites `backup-state` **whole** at
03:00, keeping only the keys it names, so a second writer would have its keys silently dropped every
night. `metrics-state` is the precedent for a job keeping its own.

Three asymmetries in the contract that look like mistakes and are not:

- **`heartbeat_at`** is read by the reboot gate and the collector, and **not** by the battery.
- **`last_ok_at`** is the mirror of that - the battery's freshness check, invisible to the reboot
  gate. It advances only on a *clean* cycle, so "failing since Tuesday" and "has never once run" do
  not look alike.
- **`phase_label`** is read only into a message, never as a metric label. It is the forbidden-label
  family: worktree path, branch, PR number, job id, session id.

**Omitted is not zero.** A key with no value is left out entirely, because the collector drops a
sample that does not parse - so an unmeasured quota *vanishes* rather than reading as 0% used, and
`agents.quota_headroom` NOTEs on the absence. `tokens_today` is written as `0` because for a phase
with no model call zero is a measurement.

## Two constraints the timing creates

- **`agents.conduct_fresh` WARNs past 600 s and a phase scope allows 5,400 s.** So conduct's loop
  must never block on a phase: it dispatches and keeps cycling. An orchestrator that waited would
  raise a warning saying it was wedged through every *successful* run, and `AgentCheckWarning` fires
  at 30 minutes - inside a normal one.
- **Being killed mid-phase is a designed path, not an accident.** `bin/reboot-when-staged.sh`
  refuses while a phase is in flight but escalates past the second refusal in a morning and applies
  the update anyway. The trade is named: a killed phase costs one re-run of minutes, against another
  month on an unapplied OS image. So conduct reconciles at startup - leases, networks, containers
  and the interrupted worktree - and nothing is reaped before 7,200 s, which is
  `agents.runners_leaked`'s own threshold and is what keeps the reconciler away from the Saturday
  smoke run.

## Accepted risks, recorded rather than left implicit

- **A phase runner has unrestricted egress.** `isolate=true` blocks more than was first assumed -
  Caddy's 443 and Jellyfin's 8096 both time out from a fleet network, because reaching a published
  port at the host's LAN address DNATs into the owning container's bridge - but the internet is
  reachable, and has to be, or `bun install`, `uv sync` and `gh` do not work. The phase-2 shape is
  an egress proxy with an allowlist; `bun`, `uv`, `git` and `gh` all honour `HTTPS_PROXY`.
- **A model phase will hold a session credential** visible in `/proc/<pid>/environ` to anything the
  agent runs, including a dependency's postinstall script. That is inherent to running the CLI in a
  container; the mitigation is the egress allowlist, not the secret mechanism. **The `check` phase
  holds none**, which is why it went first.
- **Windmill's `jwt_secret` and instance passwords are readable** by any `podman exec` on this host.
  That is true of every credential here and is bounded by who can reach the host at all.

## Commands

```bash
systemctl --user status home-server-conduct            # the loop
journalctl --user -u home-server-conduct -f
/var/agents/bin/conduct status                         # the marker, the leases, today's runs
/var/agents/bin/conduct run --project upskald --phase check --ref main
/var/agents/bin/conduct run --print-command            # the invocation, running nothing
/var/agents/bin/conduct reconcile --dry-run            # what a killed phase left behind
tail -f /var/home-server/cache/conduct/logs/*.log      # a phase's own output
systemctl --user start home-server-agents-update       # pull conduct's code now
/var/agents/bin/conduct mirror                         # fetch the project mirrors now
systemctl --user start home-server-mirror-update       # the same, through its unit
/var/agents/bin/conduct flow --check                   # has the UI edited the flow?
/var/agents/bin/conduct flow                           # rewrite it from git now
```

**A loop reporting `holding: WINDMILL_CONDUCT_TOKEN is unset` is working exactly as designed and
taking no work**, which is a state worth recognising before it is diagnosed as a fault. Read the
section below before deciding conduct is idle: holding, refusing on a busy host and failing to reach
the control plane look similar in the journal and are three different things.

## Work arrives as a suspended step, which is the human gate's mechanism reused

**conduct polls the control plane; the control plane never calls conduct.** A host-side listener
would need either a unix socket - the same `container_t -> unconfined_t : unix_stream_socket
connectto` denial that stops any container reaching the podman socket - or a TCP port on the bridge
gateway plus a firewalld hole `host/butane/ucore.bu` can only add at first boot. Both spend real
containment to give an internet-facing container an RPC that spawns `claude`. So `windmill-server`
publishes on `127.0.0.1` and conduct reaches *it*: no firewalld change, no new SELinux surface, and
**`paths.ts` carries `conduct` as an outbound-only pseudo-node that may never appear as a `to`** -
which in that file is a modelling rule and here is the security property.

**A Windmill flow step suspends; conduct answers it.** One flow, `f/agents/phase`, two modules:
`await_conduct`, an `identity` step carrying nothing but a `suspend`, and `conduct_phase`, which is
what actually waits. conduct polls `GET /jobs/queue/list?suspended=true`, fetches each suspended job
with `GET /jobs_u/get/{id}`, dispatches the phase named in the flow's arguments, and answers with
`POST /jobs/flow/resume/{id}` - the authenticated endpoint, not a signed `jobs_u` URL, which exists
so a human with no login can approve from a phone and would put a bearer secret in a log line if
conduct minted one for itself.

**Two things about that had to be measured, and the OpenAPI says otherwise on both.**
`jobs/queue/list` **declares** `args` and `flow_status` on `QueuedJob` and returns them **null** -
the list is a lightweight projection, so the schema describes the type and not what the endpoint
fills. And **a `suspend` belongs to the module it precedes**: the module carrying it reads `Success`
once it has run, and the module *after* it reads `WaitingForEvents` and is what `flow_status.step`
points at. The first version of this flow put conduct's name on the module declaring the wait, so
conduct read the id of the module that was waiting, found a name it did not own, and skipped its own
work - **no error, no log line, and a job that would have suspended for its full 24-hour timeout**.
Hence two modules, named for what each one is. `current_module` matches on the type as well as the
index, because `step` alone names whichever module the flow is at rather than one anybody is waiting
on.

Two properties fall out of using suspend, and both are load-bearing:

- **Refusing costs nothing.** A busy host means the step stays suspended and the next cycle picks it
  up. No queue of conduct's own, no work lost, and the refusal cascade can stay as blunt as it is.
- **The address is structural.** Whether a suspended step is conduct's or a human's is decided by
  the **module id**, which comes from the flow definition in git - not from a payload the step
  computed, which a step could get wrong. **conduct never answers a step it does not own**, because
  a conduct that answers approval steps is a conduct that approves its own gate. `tests/test_poll.py`
  asserts it, and that assertion fails the moment the prefix guard is removed.

**The answer is written to the database before it is delivered, never after.** A phase that
succeeded and then could not be reported - `windmill-server` restarting, the token revoked, the
network gone - is twenty minutes already spent, and rediscovering the same suspended step next cycle
would spend it again. A row in `dispatch` with a payload and no `resumed_at` means **retry the
resume and never the phase**. A crash *during* a phase is the opposite case and needs nothing new:
no row was written, the step is still suspended, and the reconciler reclaims the lease, the network,
the containers and the tree - which the reboot window's escalation already requires.

**An unset token holds; a refused one fails the cycle.** That is the *"not-configured and
configured-but-broken must differ"* rule the `pg_dumpall` leg already follows: with no
`WINDMILL_CONDUCT_TOKEN` conduct says so once a cycle and leaves `last_ok_at` advancing, because a
rollout that has not finished must not look like a fault. A **401** does the reverse and stalls the
heartbeat, because a revoked token is a fleet that has stopped taking work while every container is
healthy, every unit is active and nothing else would ever say so. `agents.conduct_fresh`'s 600 s is
far longer than a `windmill-server` restart, which is the only benign cause.

**The flow is rewritten from git at every `serve` start.** A flow is a row in Postgres that the UI
can edit with nothing in `git diff` - the exact shape `agents.worker_lanes` exists to watch - so
`conduct/flows/phase.py` is the source of truth and drift is self-healing rather than merely
detected. That costs no new check and no new metric, and it means a UI edit survives until the next
restart and no longer: the same bargain `.env` already makes. `conduct flow --check` says what a
restart would change - **after stripping Windmill's own additions by name**, because it resolves a
dependency lock into every `rawscript` module and a byte comparison therefore never matches. By name
rather than by "git's keys must match and the server may add anything", since that would also accept
a `retry:` or a `cache_ttl:` somebody added in the UI, which is the drift the check is for.

**`agents.approvals_pending` counts conduct's suspended steps as well as a human's**, and cannot
separate them in SQL - both are `suspend > 0` on the same mechanism. It is left counting both, and
its message says so: conduct claims its own within one 60s poll, so anything old enough to reach the
12-hour threshold is genuinely stuck whoever it was waiting on, which is the finding either way.

**The token is a workspace-owner token, and that is an accepted risk rather than an oversight.**
Windmill CE's scopes do not express *"may list and resume jobs and nothing else"*. What bounds it is
that `windmill-server` is on loopback, so the token is usable only from this host - and deleting it
in the UI is a browser-reachable kill switch for the fleet's ability to take work at all.

**The verify lane stopped being the semaphore when the arrow inverted**, and that is worth recording
because the quadlet still says otherwise. `windmill-worker-verify` was built as the *one verify at a
time* mechanism, on the source design where Windmill dispatched. Under polling, **conduct's
one-lease-per-project is the semaphore** - a suspended step occupies no worker at all - so the lane
is bookkeeping and spare capacity rather than a limit. `agents.worker_lanes` still asserts it listens
to `verify` alone, which remains worth knowing, and remains a row in Postgres rather than the quadlet.

## What is deliberately not built yet

**The model phases themselves.** Their precondition is built - `conduct verify`, the deny hook and
the two-tier path list all ship and are proved by planted commits rather than by a clean run - but
nothing yet calls `claude -p`. What is still missing is the prompt, the verdict schema, the podman
secret carrying the session credential, and the `ship` phase's own command. **`conduct verify` works
today and can be run by hand on any worktree**, which is deliberate: it is the half that had to
exist before there was anything to verify, so that it was written against an adversary rather than
around one.

**The approval card.** `FLAG` hits and deleted test files are collected and printed; nothing yet
puts them in front of a human. That is the polling step's, and it matters more than it sounds -
the residual that survives both the hook and verify is exactly what that card is for.

**And the publish half, step 6 of the list above.** Neither GitHub token exists yet: `conduct
verify` ends at "this commit passes the gate and changed nothing" and pushes nowhere. That is the
right order rather than an omission - there is nothing to publish until a model phase produces
commits, and creating a credential before anything can use it means it sits on the host being
neither used nor watched. When it lands it is **two** fine-grained tokens, one repository, no
`workflow` scope: `contents:write` in `.env` for conduct, `pull_requests:write` as a Windmill
workspace secret. The runner gets neither, and `tests/test_phase.py` asserts that no phase argv
carries `--secret` or a token.

**`verify` is not yet selectable as a tag.** `global_settings.custom_tags` reads `["chromium"]` and
there is no `worker__verify` row in `config`, so the lane exists and is pinned by its quadlet but
nothing can route a flow step to it. That is the polling step's problem and is named here so it is
not discovered there.
