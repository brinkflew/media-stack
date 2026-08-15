# The dashboard

A Vue 3 application, served as static files, at `https://home.avanserv.com` behind the same passkey
sign-on as everything else. It is the last item on CLAUDE.md's roadmap: *"status.json for what is
true now, keyed by stable ids, and Prometheus for when it stopped being true."*

This is the **first cut**: the shell, **System** and **Services**. Home and Library are routed
stubs that name what they will read and what has to exist first.

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
| **Prometheus** | every number and every history: container identity, health, restarts, cpu, memory, filesystems, network, GPU, disks and SMART, backup ages, `home_server_check_status` | the only thing with a time axis, and `home_server_container_info{container,unit,image,pod}` is podman's own identity join - no lookup table anywhere |
| **`status.json`** | the **prose** of the 64 findings, plus `summary`, `facts`, `generated_at`, `mode` | `message` is deliberately absent from the metric. The id is stable and alertable; the prose is readable and disposable. That split is the intended join |
| **`src/topology.ts`** | the network graph and the published-port table | the topology *is* static - it is defined in `stacks/`, in git. Only the node colouring is live |

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
