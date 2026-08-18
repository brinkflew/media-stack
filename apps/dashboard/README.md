# The dashboard

A Vue 3 application, served as static files, at `https://home.avanserv.com` behind the same passkey
sign-on as everything else. It is the last item on CLAUDE.md's roadmap: *"status.json for what is
true now, keyed by stable ids, and Prometheus for when it stopped being true."*

All five pages are built. **System** and **Services** landed first; **Home** and **Library** were
the second cut, and they needed a data layer before they needed a design - Prometheus holds counts,
and a now-playing card with a number and no title is not the design. **Network** split out of
Services on 2026-08-18 for the same reason a third time: drawing what can reach what, and what is
actually moving, needed a per-segment measurement that did not exist.

```bash
npm ci && npm run dev            # fixtures back every endpoint; no server needed
npm run build                    # vue-tsc then vite. This is the only test there is.
```

## It is read-only, and that is structural rather than a decision to revisit casually

The design has action buttons - restart, pull, approve, terminate - and **no container here can
have them.** `container_t -> unconfined_t : unix_stream_socket connectto` is DENY, `systemd --user`
for uid 1000 runs as `unconfined_t`, and that is not fixable by relabelling. Actions would need a
privileged host-side surface reachable from a browser, which is a decision to take on its own
merits rather than a checkbox to add behind a dashboard.

**So every one of those chips is a link instead**, opening the owning application in a new tab -
`src/links.ts` is the only place that mapping exists, and `ChipLink.vue` is the only place the
decision shows up in the UI. The design's layout slots and column widths are unchanged; its own
fallback chip already said "Open". One label changed rather than lying: the design's `Terminate`
became `open`, because the reachable Jellyfin target is the item page and cannot terminate anything,
and a chip that lands somewhere it cannot act is worse than one that says less.

**The container reaches nothing.** It joins `net-dashboard`, whose only other member is Caddy, and
it holds no credential of any kind. Every byte it displays arrives at the *browser*, same-origin,
through Caddy.

## Where the data comes from

```
browser ---> caddy (home.avanserv.com, import protected)
               |
               +-- /              -> dashboard:8080     the bundle, and /data/status.json
               +-- /api/prom/*    -> prometheus:9090    every number, every range query
               +-- /api/alerts/*  -> alertmanager:9093  active alerts, GET and HEAD only
```

| Source | Carries | Why not one of the others |
|---|---|---|
| **Prometheus** | every number and every history: container identity, health, restarts, cpu, memory, filesystems, network, GPU, disks and SMART, backup ages, `home_server_check_status`, and the media **counts** | the only thing with a time axis, and `home_server_container_info{container,unit,image,pod}` is podman's own identity join - no lookup table anywhere |
| **`status.json`** | the **prose** of the findings, plus `summary`, `facts`, `generated_at`, `mode` | `message` is deliberately absent from the metric. The id is stable and alertable; the prose is readable and disposable. That split is the intended join |
| **`activity.json`** (30s) | what is playing and what is in flight, **with titles**: sessions, downloads, transcodes, torrents | a title cannot be a Prometheus label. Cardinality is the obvious reason and the lesser one - see below |
| **`library.json`** (5min) | requests, recently added, recent completions, the stalled and queued files, the subtitle backlog | same, on the cadence its contents actually change at |
| **`src/topology.ts`** | the segment rails and the published-port table | the topology *is* static - it is defined in `stacks/`, in git. Only the node colouring is live |
| **`src/paths.ts`** | who talks to whom, and why | half of these edges live in an application's own DATABASE - the \*arr download client, Prowlarr's FlareSolverr tag - so git cannot derive them. `bin/lint-repo.sh` validates instead: both endpoints must share a segment, because every bridge is `isolate=true` |

### The two documents are not series, and must never become them

`bin/collect-metrics.py` refuses to label a Jellyfin session with the user, the device or the item.
The comment says why: a 400-day series of who watched what is *surveillance of the household* rather
than monitoring of a machine. Home needs exactly that data to draw a now-playing card, so it travels
as a document instead - **rewritten whole every run, with no history anywhere**. That difference is
the entire justification. The moment any of it grows a retention window, the refusal has been
reversed by accident.

They are split by **cadence, not by page** - both pages read both - for the reason the collector's
own `home-server-slow.prom` already records: a five-minute slice living in a thirty-second file
blinks out nine ticks in ten and renders as a sawtooth that looks exactly like a fault.

**`sources` is not optional.** Each document carries one `{ok, at, error}` per upstream it consulted,
because without it "jellyseerr timed out" and "there are no pending requests" are the same empty
list. It is `mode.routes: false` applied to applications.

### Posters come same-origin, and carry no credential

Jellyfin's `/Items/*/Images/*` answers **200 unauthenticated** while every other path on it answers
401 - measured from inside the Caddy container. So `home.{$DOMAIN}` proxies just that, GET and HEAD
only, path-guarded, and a mis-scoped matcher fails closed into Jellyfin's own 401 rather than opening
its API. Not `watch.{$DOMAIN}`: that is cross-origin, pays the measured 5x NAT-loopback penalty on
30-60 images a load, and hangs the poster grid off a route deliberately outside sign-on.

Only a **tagged** request gets a long cache. The tag is a content hash, so changed artwork changes
the URL; an untagged request is whatever the current image happens to be.

**There is no log stream, and the design's slot for one now holds Alertmanager.** CLAUDE.md is
explicit: Jellyfin alone emits 2,644 priority-3 lines a day of ffmpeg decoder chatter with no lever
to stop it, so a live tail is noise with a cursor on it. Alertmanager groups, suppresses repeats
and reports resolution - and had no interface at all before this.

### `status.json` is copied, not mounted

`/var/lib/home-server/status.json` is written by `bin/verify-host.sh` through `sudo`, so it is
root-owned inside a `var_lib_t` directory. `container_t` may not read that, and **`:z` cannot
rescue it**: relabelling on a rootless mount is done by the invoking user, and `core` does not own
that directory, so `chcon` fails `EPERM` - the mount is accepted and the container gets permission
denied. So the same bytes are written a second time, as `core`, into
`${DOCKER_VOLUME_CACHE}/dashboard/`, which is bind-mounted `:z,ro`. Same shape as node-exporter's
textfile drop, and safe to relabel for the same reason: small, dedicated, ours.

An absent file is reported as *"the check battery has never run here"*, which is a fresh host - a
different thing from a broken one.

## What the Network page can and cannot say

**Per-flow accounting does not exist on this host and cannot be made to.** `nsenter -n` into a
rootless netns is `EPERM` as `core`, and `/proc/net/nf_conntrack` is root-only - so there is no
container-A-to-container-B number anywhere, and anything that appears to be one is an inference.

What IS measured, by `source_container_network` in `bin/collect-metrics.py`, is a container's bytes
on a **segment**: `home_server_container_network_{receive,transmit}_bytes_total{container,network}`.
It reads `/proc/<pid>/net/dev` from the host as `core`, which works for the exact reason
node-exporter's filesystem collector fails - rootless podman maps container uid 0 to `core`, so
`ptrace_may_access` passes, where host PID 1 is real root and does not.

So the drawing is **bipartite on purpose**: a rail is a segment, a box is a container, and the only
line carrying a rate is the **spoke** between them. There is no point-to-point arrow with a number on
it, because there is no number to put on one. Declared routes from `paths.ts` are a second language -
they appear on hover, they are static, and they never animate. Reachability is asserted by git;
motion is asserted by measurement; neither borrows the other's credibility.

**A two-member segment is not automatically an exact edge**, which was the first guess and it is
wrong. Every bridge also has a gateway to the outside: `net-dashboard` mirrors
(`caddy.tx ~ dashboard.rx` and back), but `net-solver` does not - `prowlarr.tx` is 352 KB against
`flaresolverr.rx` of 36 MB, because FlareSolverr is headless Chrome fetching indexer pages and nearly
all of it is internet egress. Reconcile on **rates**, never on the raw counters: containers have
different start times, so their totals cover different windows.

## The four things that will bite

- **A stale dashboard must read as stale, never as healthy.** `src/stores/host.ts` tracks three
  independent freshness primitives - `generated_at` from the file, the collector's last success,
  and `up` - because each fails in a way the others cannot see. Past threshold the banner appears,
  panels dim and say what is stale, and `verdict` returns `unknown` rather than folding into
  `fail`. "The battery says everything passed" and "nobody has asked the battery" must not look
  alike.
- **An expired session is a 302, not a 401.** `forward_auth` redirects to `auth.avanserv.com`, and
  `fetch` follows redirects - so an XHR *resolves*, with `res.ok` true and an HTML sign-in page as
  its body. `src/api/http.ts` is the single place that detects it, and it reloads the page, because
  a passkey prompt cannot be completed inside an XHR. The reload is rate-limited to once per 30s so
  that a 502 page from a restarting upstream cannot turn into an infinite refresh.
- **`mode.routes: false` means the route battery did not run.** The hourly timer passes `--quiet`,
  not `--routes`, so this is the normal case. The Findings panel says so explicitly; those checks
  are absent, not passing.
- **Everything here must be ASCII.** `bin/lint-repo.sh` fails the whole repository on one byte above
  `0x7F`, and that covers every `.vue`, `.ts` and `.css`. No em dashes, no curly quotes, no unicode
  glyphs as icons - use inline SVG. `node_modules/` is untracked and `.woff2` is skipped as binary,
  so only the sources and `package-lock.json` are in scope.

## Layout

| Path | What |
|---|---|
| `src/queries.ts` | **every PromQL expression this app issues.** The interface between the dashboard and `bin/collect-metrics.py`, in one readable file |
| `src/topology.ts` | the network map, checked against `stacks/` by `bin/lint-repo.sh` |
| `src/paths.ts` | the declared routes. Validated, not derived - see below |
| `src/graph.ts` | the topology's coordinate arithmetic, the way `charts.ts` is the chart's. No Vue, no DOM, so `fixtures/smoke.mjs` can check it |
| `src/composables/useTooltip.ts` | one tooltip, module-level, the `useCrosshair` shape |
| `src/stores/host.ts` | `status.json`, the freshness primitives, the verdict |
| `src/api/` | `http.ts` (the sign-on trap), `prometheus.ts`, `status.ts`, `alerts.ts` |
| `src/charts.ts` | SVG path arithmetic. **No chart library** - the design is hand-drawn SVG, and a gap in a series must break the line rather than being drawn across |
| `src/composables/usePoll.ts` | stops when the tab is hidden; keeps the last value on a failed poll and does not advance `lastOk` |
| `src/styles/tokens.css` | the design system, transcribed rather than reinterpreted |
| `fixtures/` | a synthetic, **deliberately unhealthy** host. Dev only; nothing under `src/` imports it |

**`src/topology.ts` is a second copy of what `stacks/` already declares**, which CLAUDE.md calls the
most driftable shape this repository has a name for. It is acceptable only because
`bin/lint-repo.sh` parses both and fails on any difference. No container may run
`podman network inspect` - the socket is SELinux-denied - so discovering it at run time is not
available, and these files are the authority anyway.

## Developing

**The fixtures are deliberately unhealthy.** A fixture where everything passes exercises the state
that needs the least design work; the interesting layouts are an actionable strip with something in
it, a container in a restart loop, a disk with a reallocated sector, thirty days of uptime where
six are missing. So the synthetic host has all of those, and they are failures the real one has
actually had.

`fixtures/prometheus.ts` answers by **exact query string** against `src/queries.ts`, and warns at
startup about any catalogued query it does not cover. A fixture that has quietly stopped covering
the real queries is the same shape of problem as a lint that matches nothing.

`fixtures/media.ts` is typed against `src/types.ts`, which `tsconfig.node.json` includes - so a
fixture that drifts from the contract `bin/collect-metrics.py` writes is a **compile error**, not a
panel that quietly renders nothing. Same idea as `uncovered()`, through the type system.

**Four environment switches, because these states cannot share a screen.** Editing a constant to see
one means a diff to remember to revert:

```bash
HS_FIX_PLAYBACK_AGE=40  npm run dev   # the frozen card: extrapolation stops, the bar greys
HS_FIX_PLAYBACK_AGE=500 npm run dev   # every stale path at once
HS_FIX_EMPTY=1          npm run dev   # nothing playing, nothing in flight - the COMMON state
HS_FIX_BROKEN=jellyseerr npm run dev  # "absent, not zero" for one upstream
```

**`HS_FIX_EMPTY=1` is the one to look at first.** An almost-empty Library table is the normal,
healthy rendering on the real host - `queued/` holds no video files because the reconciler works, and
Tdarr's table drains to zero by design. So that state has to look finished rather than broken, and it
must not read as healthy when it is merely *unmeasured*: stale-and-empty says "no rows as of 8m ago",
never "nothing in flight".

Two harnesses, neither of them a test suite:

```bash
node fixtures/smoke.mjs               # drives the row model, sort, links and posters in node
node fixtures/shoot.mjs /tmp          # screenshots all four pages, reports console errors
```

`smoke.mjs` needs nothing but vite. `shoot.mjs` needs playwright, which is **deliberately not a
dependency** - it says so and exits 2 rather than being quietly unrunnable.

Against the real Prometheus instead - it publishes no host port, so tunnel to its bridge address:

```bash
ip=$(ssh home.local "podman inspect prometheus --format '{{.NetworkSettings.Networks.\"net-metrics\".IPAddress}}'")
ssh -L 9090:"$ip":9090 home.local
VITE_PROM=http://localhost:9090 npm run dev     # fixtures are dropped entirely
```

## Deploying

The image is built **on the server, from the checkout**, by `dashboard.build`. Nothing but source is
committed - `dist/` and `node_modules/` are ignored - so `home-server-dashboard-build.timer` is not
just an update mechanism, **it is the deploy path**: a `git pull` that changes `src/` deploys
nothing until it runs. Nightly at 23:00, an hour before `podman-auto-update`.

```bash
# on the server, to see a change now rather than tomorrow
systemctl --user start home-server-dashboard-build.service
systemctl --user restart dashboard.service
```

Verified before shipping:

```bash
npm run build                                    # vue-tsc, then vite
./bin/lint-repo.sh                               # ASCII, topology drift, quadlet dryrun
podman run --rm -v "$PWD/apps/dashboard/Caddyfile:/etc/caddy/Caddyfile:ro" \
  docker.io/library/caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

**`caddy validate` cannot see the mistake that matters.** The two guards on `home.{$DOMAIN}` - the
403 on Prometheus' admin API and the 405 on Alertmanager's write paths - were written at the top
level of the site block first, where they adapted cleanly, validated cleanly, and did **nothing**:
Caddy orders `handle` before `respond`, so the first `handle` terminated the request and neither
matcher ever ran. A GET of `/api/prom/api/v1/admin/tsdb/snapshot` returned 200. They live inside
their `handle_path` blocks now. **Test them with a request after touching them.**
