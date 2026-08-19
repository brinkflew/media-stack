# Logs, metrics and alerting

Lifted whole from `CLAUDE.md` on 2026-08-19. Nothing here was rewritten.

Three layers that answer different questions: `status.json` says what is true now, Prometheus
says when it stopped being true, and Alertmanager is the only one that leaves the house.

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

**Those numbers are HISTORY, not the current state, and the difference matters if you are reading
this to decide whether something is wrong.** Measured 2026-08-19: **9 indexers, all 9 enabled, no
health issues at all** - the dead ones were removed rather than repaired. The metric did its job.
Read it live before acting on the paragraph above:

```bash
KEY=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' config/prowlarr/config.xml)
podman exec prowlarr curl -sf -H "X-Api-Key: $KEY" http://localhost:9696/api/v1/indexer \
  | jq -r '"total=\(length) enabled=\([.[]|select(.enable)]|length)"'
```

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
`docs/backups.md` rather than here because it breaks the backup rather than the metrics.

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

**`CheckFailing` covers all 196 check ids and every future one - but only at FAIL.** Its expression
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
