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
git clone --local mirrors/<project>.git worktrees/<id>
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

**Everything past `check`.** The model phases need the deny hook and the gate-file diff check first;
`.claude/settings.json` and `scripts/pr_quality_gate.py` are tracked files on the branch, inside the
writable mount, and `make check` does not check them.

**`verify` is not yet selectable as a tag.** `global_settings.custom_tags` reads `["chromium"]` and
there is no `worker__verify` row in `config`, so the lane exists and is pinned by its quadlet but
nothing can route a flow step to it. That is the polling step's problem and is named here so it is
not discovered there.
