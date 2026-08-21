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
| the upskald mirror | `cache/conduct/mirrors/upskald.git` | **rsynced from a workstation** |

**The server holds no GitHub credential beyond that one deploy key**, and the key can fetch one
private repository and nothing else. That is why the mirror is seeded from a machine that already
has credentials rather than cloned here: the check phase needs a static mirror, and refreshing it is
what will need a credential, later, deliberately.

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
  worker mid-job rather than on the phase that caused it. `/tmp` is sized *below* the memory
  ceiling for the same class of reason: tmpfs pages are charged to the cgroup, so a larger `/tmp`
  turns "No space left on device" into an OOM kill that names nothing.

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
```

## What is deliberately not built yet

**Windmill polling.** conduct reconciles, heartbeats and runs a phase on demand; it takes no work
from the control plane. That half lands next, against
`GET /jobs/queue/list?suspended=true` and the authenticated resume above. Phase execution went first
because it is the half where the uncertainty was - the cgroups, the caches, the SELinux labels, the
service-name addressing - and none of that is easier to debug with a flow in front of it.

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
