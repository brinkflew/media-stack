#!/usr/bin/env python3
# ==============================================================================
# The numbers no container can honestly measure about this host
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, from a systemd user timer. See host/systemd/.
#
# Prometheus PULLS and has no push endpoint, so this writes Prometheus exposition
# format into node-exporter's textfile directory and node-exporter serves it as
# part of its own scrape. That is the standard mechanism for exactly this, and it
# pays for itself twice: node_textfile_mtime_seconds dates the file, so a stopped
# collector is visible from OUTSIDE the collector, and node_textfile_scrape_error
# flags a malformed one. Neither is something this script could honestly assert
# about itself - see bin/verify-host.sh's note on why a check cannot grade its
# own liveness.
#
# WHY ANY OF THIS IS HERE RATHER THAN IN AN EXPORTER. Three separate reasons,
# each measured rather than assumed:
#
#   node_filesystem_*   NO ROOTLESS CONTAINER CAN PRODUCE IT. node-exporter reads
#                       /proc/1/mountinfo for the host mount table, and reading
#                       another user's /proc entry must pass ptrace_may_access:
#                       host PID 1 is real root, and rootless podman maps
#                       container uid 0 to core. It failed EACCES on every
#                       scrape. On the host a plain statvfs answers.
#   node_network_*      /proc/net is a symlink to self/net, so it resolves in the
#                       READER's network namespace. A bridge-networked
#                       node-exporter reports its own container's interfaces
#                       while looking exactly like it reports the host's.
#                       Network=host would fix it and cost more - it reaches the
#                       host through pasta at 169.254.1.2, which bypasses
#                       firewalld, so every container could then read host
#                       telemetry.
#   home_server_container_memory_*
#                       cAdvisor exports memory.current and stops. CLAUDE.md
#                       spends twenty lines establishing that memory.current and
#                       memory.events high are MISLEADING here - Jellyfin sits at
#                       its 3G MemoryHigh with 0.385G anon, 2.338G cold page
#                       cache and zero stall - and names the five numbers that
#                       settle it. Four of them have no cAdvisor metric at all.
#
# THE NAMING RULE, because half of what follows is somebody else's name and half
# is ours. An upstream name is adopted ONLY where the semantics match exactly -
# same quantity, same unit, same reset behaviour - so that this implementation
# can be replaced without touching a dashboard. Where they only almost match, a
# home_server_* name is minted instead: a wrong number under a right name is
# undetectable from a dashboard, while a right number under an unfamiliar name
# is merely inconvenient. The sharpest case is memory.high, which cAdvisor would
# have called container_spec_memory_reservation_limit_bytes and which means
# memory.low there - see the note at that metric.
#
# A DIAGNOSTIC MUST NEVER BREAK THE THING IT ANNOTATES. Every source is called
# inside its own try/except with a subprocess timeout; one that fails drops its
# own series, records itself in home_server_collector_source_up, and changes
# nothing else. The file is written atomically, so a reader never sees half of
# one. This script writes nowhere except that file and its own marker.
#
# Usage:
#   bin/collect-metrics.py            collect and write   (what the timer runs)
#   bin/collect-metrics.py --print    collect, print to stdout, write nothing
#   bin/collect-metrics.py --slow     force the 5-minute tier this run
#   bin/collect-metrics.py --source smart        one source only, tier ignored
# ==============================================================================

import calendar
import glob
import json
import os
import subprocess
import sys
import time

CACHE = os.environ.get("DOCKER_VOLUME_CACHE", "/var/home-server/cache")
TEXTFILE = os.path.join(CACHE, "textfile", "home-server.prom")
TEXTFILE_SLOW = os.path.join(CACHE, "textfile", "home-server-slow.prom")
MARKER = os.path.expanduser("~/.cache/home-server/metrics-state")

# THE TWO DOCUMENTS, AND WHY THEY ARE NOT SERIES.
#
# The dashboard's Home and Library pages need titles: what is playing, who
# asked for what, which file is stuck. None of that can be a Prometheus label.
# Cardinality is the obvious reason and it is the lesser one - the real one is
# that source_playback below deliberately refuses to label a session with the
# user, the device or the item, because a 400-day series of who watched what is
# surveillance of the household rather than monitoring of a machine.
#
# A document is a different object from a series and that difference is the
# whole argument: it is rewritten whole on every run, nothing accumulates, and
# there is no history to mine. It answers "what is happening" and cannot answer
# "what happened in March". Keep it that way - the moment any of this grows a
# retention window, the refusal above has been reversed by accident.
#
# Split by CADENCE, not by page, for the reason TEXTFILE_SLOW already records: a
# five-minute slice living in a thirty-second file would blink out nine ticks in
# ten. So the split follows rate of change - a progress bar goes in the fast
# one, a request queue in the slow one - and each carries its own generated_at
# so the two go stale independently and the UI can say which one did.
DOC_DIR = os.path.join(CACHE, "dashboard")
DOC_ACTIVITY = os.path.join(DOC_DIR, "activity.json")
DOC_LIBRARY = os.path.join(DOC_DIR, "library.json")
DOC_SCHEMA = 1

# How many not-yet-available requests get a title resolved per slow run. Each
# one costs a separate call to jellyseerr's TMDB proxy, and the Requests panel
# shows a handful - so the cap is the panel's depth plus headroom, NOT the 104
# requests this host has. Named and logged rather than silent, because a cap
# nobody can see reads as "that is all there is".
REQUEST_TITLE_BUDGET = 12

# The library tree, at the three prefixes three different processes see it
# under. bin/promote-transcoded.py documents this at length; the collector needs
# the same mapping to join a Tdarr row to an *arr record to a path on disk.
MEDIA_HOST = "/mnt/media/library"
MEDIA_ARR = "/data/library"
MEDIA_TDARR = "/media/library"
MEDIA_TYPES = ("movies", "documentaries", "series", "anime")

# The cgroup root the user manager delegates. `io` is NOT delegated by default -
# `cpu memory pids` are - and an undelegated controller is accepted silently and
# does nothing, which is why host/butane/ucore.bu ships the drop-in. If this path
# is wrong every container source returns nothing rather than wrong numbers.
CGROUP = ("/sys/fs/cgroup/user.slice/user-%d.slice/user@%d.service/app.slice"
          % (os.getuid(), os.getuid()))

# An ALLOWLIST, not an exclusion regex, and that is the whole point: rootless
# podman creates dozens of overlay mounts under ~/.local/share/containers, and a
# regex fails OPEN when something new appears. This fails closed. /mnt and /home
# are symlinks into /var on CoreOS, so the canonical kernel paths are used - the
# same reason the mount unit is var-mnt-media.mount.
#
# `/` IS DELIBERATELY ABSENT. It is the read-only composefs: 8 MB, 0 bytes free,
# 100% full by design and for ever. A panel showing the root filesystem full
# would read as an emergency and mean nothing, which is worse than showing
# nothing - and statvfs on it returns -1 for the inode counts, so it emits
# negative gauges as well. The three filesystems below are the ones that can
# actually fill up.
FILESYSTEMS = ("/boot", "/var", "/var/mnt/media")


def now():
    return time.time()


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def read_kv(path):
    """A cgroup 'key value' file as a dict of ints. Missing file -> {}."""
    out = {}
    try:
        for line in read_text(path).splitlines():
            parts = line.split()
            if len(parts) == 2:
                try:
                    out[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def read_int(path):
    """A single-value cgroup file. 'max' and a missing file both -> None."""
    try:
        raw = read_text(path).strip()
    except OSError:
        return None
    if raw in ("", "max"):
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def read_pressure(path):
    """PSI totals in seconds, as {'some': float, 'full': float}.

    The total= field is a monotonic microsecond counter and is the only part
    worth exporting. avg10/avg60/avg300 are already averaged over a window the
    query cannot change, so exporting them would bake that window into the
    schema for ever - rate() over the counter is strictly more useful.
    """
    out = {}
    try:
        for line in read_text(path).splitlines():
            parts = line.split()
            if not parts:
                continue
            for field in parts[1:]:
                if field.startswith("total="):
                    try:
                        out[parts[0]] = int(field[6:]) / 1e6
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def run(argv, timeout=10):
    """Capture stdout, or None. Never raises, never blocks for ever."""
    try:
        res = subprocess.run(argv, capture_output=True, text=True,
                             timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode != 0:
        return None
    return res.stdout


class Metrics:
    """An exposition-format accumulator.

    HELP and TYPE are emitted once per metric name, on first use, so the file
    stays valid for anything that consumes it - including a future exporter that
    serves it verbatim rather than through the textfile collector.
    """

    def __init__(self):
        self.lines = []
        self.declared = set()
        self.count = 0

    def add(self, name, value, labels=None, help_text="", kind="gauge"):
        if value is None:
            return
        if name not in self.declared:
            self.declared.add(name)
            if help_text:
                self.lines.append("# HELP %s %s" % (name, help_text))
            self.lines.append("# TYPE %s %s" % (name, kind))
        if labels:
            rendered = ",".join(
                '%s="%s"' % (k, str(v).replace("\\", "\\\\")
                             .replace('"', '\\"').replace("\n", " "))
                for k, v in sorted(labels.items()))
            self.lines.append("%s{%s} %s" % (name, rendered, value))
        else:
            self.lines.append("%s %s" % (name, value))
        self.count += 1

    def render(self):
        return "\n".join(self.lines) + "\n"


class Document:
    """A JSON document accumulator, with a per-upstream answered/did-not record.

    `sources` IS NOT OPTIONAL and it is the only reason this class exists rather
    than a plain dict. Without it, "jellyseerr timed out" and "there are no
    pending requests" are the same bytes - an empty list either way - and a page
    rendering that as "nothing to approve" is the exact failure this repository
    is written around. It is `mode.routes: false` applied to applications:
    absent must never read as zero.

    Nullable values are written as null and never omitted, so a key cannot
    appear and disappear between runs and force a reader to guess which case it
    is in. Same contract as verify-host.sh's `facts`.
    """

    def __init__(self):
        self.body = {}
        self.sources = {}

    def note(self, name, ok, error=None):
        """Record that an upstream did or did not answer this run."""
        self.sources[name] = {
            "ok": bool(ok),
            "at": iso(now()) if ok else None,
            "error": None if ok else (error or "did not answer"),
        }

    def set(self, key, value):
        self.body[key] = value

    def append(self, key, value):
        self.body.setdefault(key, []).append(value)

    def render(self, started):
        doc = {"schema": DOC_SCHEMA, "generated_at": iso(started)}
        doc.update(self.body)
        doc["sources"] = self.sources
        # sort_keys for a stable diff; ensure_ascii because a title can hold
        # anything and this repository is ASCII end to end - a \uXXXX escape is
        # still ASCII on the wire and decodes correctly in the browser.
        return json.dumps(doc, sort_keys=True, ensure_ascii=True,
                          separators=(",", ":")) + "\n"


def iso(when):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(when))


# ------------------------------------------------------------------------------
# Host filesystems
# ------------------------------------------------------------------------------
# node_exporter's names and label set exactly, because the semantics are
# identical - statfs is statfs. That is what makes this replaceable: if a future
# host ever CAN run the filesystem collector, swapping it in is a deployment
# change and not a dashboard rewrite.

def source_filesystems(m):
    mounts = {}
    for line in read_text("/proc/self/mountinfo").splitlines():
        parts = line.split()
        try:
            sep = parts.index("-")
        except ValueError:
            continue
        mountpoint = parts[4].replace("\\040", " ")
        if mountpoint in FILESYSTEMS and mountpoint not in mounts:
            mounts[mountpoint] = (parts[sep + 1], parts[sep + 2])

    for mountpoint in FILESYSTEMS:
        if mountpoint not in mounts:
            # Absent, not zero. A mountpoint that is not mounted must not read
            # as a full disk - and statvfs on the path would cheerfully report
            # the filesystem UNDERNEATH it, which is how /var/mnt/media would
            # come to show 186G free off the NVMe.
            m.add("home_server_filesystem_mounted", 0,
                  {"mountpoint": mountpoint},
                  "1 when the expected mountpoint is actually mounted.")
            continue
        fstype, device = mounts[mountpoint]
        labels = {"device": device, "fstype": fstype, "mountpoint": mountpoint}
        m.add("home_server_filesystem_mounted", 1, {"mountpoint": mountpoint})
        try:
            st = os.statvfs(mountpoint)
        except OSError:
            m.add("node_filesystem_device_error", 1, labels,
                  "1 if an error occurred while getting statistics.")
            continue
        m.add("node_filesystem_device_error", 0, labels)
        m.add("node_filesystem_size_bytes", st.f_blocks * st.f_frsize, labels,
              "Filesystem size in bytes.")
        m.add("node_filesystem_free_bytes", st.f_bfree * st.f_frsize, labels,
              "Filesystem free space in bytes.")
        m.add("node_filesystem_avail_bytes", st.f_bavail * st.f_frsize, labels,
              "Filesystem space available to non-root users in bytes.")
        m.add("node_filesystem_files", st.f_files, labels,
              "Filesystem total file nodes.")
        m.add("node_filesystem_files_free", st.f_ffree, labels,
              "Filesystem total free file nodes.")
        m.add("node_filesystem_readonly", 1 if st.f_flag & os.ST_RDONLY else 0,
              labels, "Filesystem read-only status.")


# ------------------------------------------------------------------------------
# Host network
# ------------------------------------------------------------------------------
# The host has only lo and nic0: every podman bridge lives inside the rootless
# network namespace, not here. veth* is excluded anyway, because netavark
# recreates one per container per network on every restart and
# podman-auto-update restarts everything nightly - a device label would mint
# thousands of dead series a year.

def source_network(m):
    for line in read_text("/proc/net/dev").splitlines()[2:]:
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        name = name.strip()
        if name.startswith("veth"):
            continue
        f = rest.split()
        if len(f) < 16:
            continue
        labels = {"device": name}
        for metric, idx, help_text in (
                ("receive_bytes_total", 0, "Network device statistic receive_bytes."),
                ("receive_packets_total", 1, "Network device statistic receive_packets."),
                ("receive_errs_total", 2, "Network device statistic receive_errs."),
                ("receive_drop_total", 3, "Network device statistic receive_drop."),
                ("transmit_bytes_total", 8, "Network device statistic transmit_bytes."),
                ("transmit_packets_total", 9, "Network device statistic transmit_packets."),
                ("transmit_errs_total", 10, "Network device statistic transmit_errs."),
                ("transmit_drop_total", 11, "Network device statistic transmit_drop.")):
            m.add("node_network_" + metric, int(f[idx]), labels, help_text,
                  "counter")
        try:
            state = read_text("/sys/class/net/%s/operstate" % name).strip()
            m.add("node_network_up", 1 if state == "up" else 0, labels,
                  "Value is 1 if operstate is 'up', 0 otherwise.")
        except OSError:
            pass


# ------------------------------------------------------------------------------
# Containers
# ------------------------------------------------------------------------------
# THE JOIN KEY IS PODMAN'S OWN PODMAN_SYSTEMD_UNIT LABEL, never a name derived
# from the container. It is what makes torrent-infra resolve to
# torrent-pod.service without a hand-maintained lookup table - and a table
# maintained in a script is the most driftable thing this repository could own.
# home_server_container_identity_unresolved counts what did not map, because the
# failure would otherwise be silent: a container simply missing from every panel.

HEALTH_STATES = {"healthy": 0, "starting": 1, "unhealthy": 2}

# The kernel's PSI vocabulary mapped onto cAdvisor's. They mean the same thing:
# `some` is "at least one task was delayed", `full` is "every runnable task
# was". Anything the kernel adds later is skipped rather than guessed at.
PSI_LEVELS = {"some": "waiting", "full": "stalled"}


def source_containers(m):
    raw = run(["podman", "ps", "--format", "json"], timeout=20)
    if raw is None:
        raise RuntimeError("podman ps failed")
    containers = json.loads(raw)

    unresolved = 0
    for c in containers:
        name = (c.get("Names") or ["?"])[0]
        unit = (c.get("Labels") or {}).get("PODMAN_SYSTEMD_UNIT", "")
        if not unit:
            unresolved += 1
            continue
        base = os.path.join(CGROUP, unit)
        if not os.path.isdir(base):
            unresolved += 1
            continue

        labels = {"container": name}
        m.add("home_server_container_info", 1,
              {"container": name, "unit": unit,
               "image": c.get("Image", ""), "pod": c.get("PodName", "")},
              "Container identity. Everything that changes at deploy time "
              "rather than sample time lives here and is joined, so a nightly "
              "image update costs one series per container and not one per "
              "series.")
        m.add("home_server_container_running",
              1 if c.get("State") == "running" else 0, labels,
              "1 when the container is running.")
        m.add("home_server_container_restarts_total", c.get("Restarts", 0),
              labels, "Restart count as podman reports it. Resets when the "
              "container is recreated, which auto-update does nightly.",
              "counter")
        m.add("container_start_time_seconds", _started_at(c), labels,
              "Unix timestamp the container started.")

        # duckdns, unpackerr and the pod's infra container define no
        # healthcheck. The health gauge is ABSENT for them rather than zero,
        # and the _defined gauge says which case a reader is in - a check that
        # assumes every container reports health marks those three broken for
        # ever.
        status = c.get("Status", "")
        state = next((s for s in HEALTH_STATES if "(%s)" % s in status), None)
        m.add("home_server_container_healthcheck_defined",
              1 if state else 0, labels,
              "1 when the container defines a healthcheck at all.")
        if state:
            m.add("home_server_container_health", HEALTH_STATES[state], labels,
                  "0 healthy, 1 starting, 2 unhealthy. Absent when the "
                  "container defines no healthcheck.")

        _container_cgroup(m, labels, base)

    m.add("home_server_container_identity_unresolved", unresolved, None,
          "Containers that could not be mapped to a cgroup. Non-zero means the "
          "PODMAN_SYSTEMD_UNIT join has broken and some containers are missing "
          "from every panel.")
    m.add("home_server_containers", len(containers), None,
          "Containers podman reports.")


def _started_at(c):
    value = c.get("StartedAt")
    return value if isinstance(value, (int, float)) else None


def _container_cgroup(m, labels, base):
    """The memory numbers that distinguish a full cache from a starved cgroup.

    THIS IS THE WHOLE REASON THIS SCRIPT TOUCHES CONTAINERS AT ALL. Jellyfin
    sits at its MemoryHigh with a fast-climbing `high` counter and is perfectly
    healthy: anon 0.385G against 2.338G of cold, clean page cache, pgsteal
    tracking pgscan to five digits, and zero total stall. Reading memory.current
    alone reproduces exactly the misdiagnosis CLAUDE.md already records.
    """
    stat = read_kv(os.path.join(base, "memory.stat"))
    current = read_int(os.path.join(base, "memory.current"))
    inactive_file = stat.get("inactive_file")

    # THE NUMBER THAT WOULD HAVE PREVENTED THE MISDIAGNOSIS, under the name the
    # rest of the world already uses for it. Working set is what is genuinely
    # resident: memory.current minus the cold, clean page cache the kernel can
    # drop for nothing. Jellyfin reads ~0.66G here against a memory.current of
    # 3.00G at a 3G ceiling - the same cgroup, the same instant, and the only
    # one of the two numbers worth alerting on.
    if current is not None and inactive_file is not None:
        m.add("container_memory_working_set_bytes",
              max(current - inactive_file, 0), labels,
              "Memory usage minus inactive file cache - what is actually "
              "resident and not free to reclaim. Alert on THIS, never on "
              "container_memory_usage_bytes.")

    # cAdvisor's names, adopted verbatim: same cgroup fields, same units, same
    # meaning, so this implementation can be swapped out without touching a
    # dashboard. The missing _bytes suffix on rss and cache is cAdvisor's wart
    # rather than ours, and reproducing it faithfully is the whole point - a
    # name that is ALMOST the upstream one is worse than either, because it
    # breaks silently on the day something else serves it.
    m.add("container_memory_rss", stat.get("anon"), labels,
          "Anonymous memory - the actual working set.")
    m.add("container_memory_cache", stat.get("file"), labels,
          "Page cache charged to this cgroup.")

    # No upstream equivalent, and load-bearing: the split between cold and warm
    # cache is the difference between 'at its ceiling' and 'in trouble'.
    m.add("home_server_container_memory_inactive_file_bytes", inactive_file,
          labels,
          "Cold, clean page cache. Reclaimable at essentially no cost.")
    m.add("home_server_container_memory_active_file_bytes",
          stat.get("active_file"), labels, "Recently used page cache.")
    for key, metric, help_text in (
            ("pgscan", "pgscan_total", "Pages scanned for reclaim."),
            ("pgsteal", "pgsteal_total",
             "Pages successfully reclaimed. Tracking pgscan means reclaim is "
             "free; falling short of it means it is not."),
            ("workingset_refault_file", "workingset_refault_file_total",
             "Pages reclaimed and then immediately needed again - real thrash, "
             "as opposed to a cgroup simply holding cache.")):
        m.add("home_server_container_memory_" + metric, stat.get(key), labels,
              help_text, "counter")

    m.add("container_memory_usage_bytes", current, labels,
          "memory.current. MISLEADING ON ITS OWN - a cgroup doing file I/O sits "
          "at its ceiling by design. Read container_memory_working_set_bytes.")
    m.add("container_memory_max_usage_bytes",
          read_int(os.path.join(base, "memory.peak")), labels,
          "High-water mark since the cgroup was created.")
    m.add("container_spec_memory_limit_bytes",
          read_int(os.path.join(base, "memory.max")), labels,
          "The MemoryMax= hard limit.")

    # MINTED DELIBERATELY, and this is the sharpest case for the naming rule.
    # cAdvisor's container_spec_memory_reservation_limit_bytes reads like the
    # name for this and is NOT: it maps to memory.low, a reservation, where this
    # is memory.high, a throttle watermark. Publishing MemoryHigh under that
    # name would show a container pressed against a limit it is not at - the
    # exact misdiagnosis container_memory_working_set_bytes exists to prevent,
    # reintroduced through the label instead of the number.
    m.add("home_server_container_memory_high_bytes",
          read_int(os.path.join(base, "memory.high")), labels,
          "The MemoryHigh= throttle watermark, NOT memory.low.")

    events = read_kv(os.path.join(base, "memory.events"))
    for key in ("high", "max", "oom", "oom_kill"):
        if key in events:
            ev = dict(labels)
            ev["event"] = key
            m.add("home_server_container_memory_events_total", events[key], ev,
                  "memory.events. `high` on its own proves NOTHING - a cgroup "
                  "doing file I/O always accumulates it. `oom_kill` is the one "
                  "that is unambiguous.", "counter")

    # cAdvisor's PSI names, adopted verbatim. Note the vocabulary differs from
    # the kernel's and means the same thing: PSI writes some/full, cAdvisor says
    # waiting/stalled - some is "at least one task was delayed", full is "every
    # runnable task was". The level therefore lives in the metric NAME here
    # rather than in a label, which is what upstream does.
    for controller in ("cpu", "memory", "io"):
        for level, seconds in read_pressure(
                os.path.join(base, "%s.pressure" % controller)).items():
            if level not in PSI_LEVELS:
                continue
            m.add("container_pressure_%s_%s_seconds_total"
                  % (controller, PSI_LEVELS[level]), "%.6f" % seconds, labels,
                  "PSI total stall. The arbiter: real starvation shows here, "
                  "and a cgroup merely holding cache does not.", "counter")

    cpu = read_kv(os.path.join(base, "cpu.stat"))
    for key, metric in (("usage_usec", "container_cpu_usage_seconds_total"),
                        ("user_usec", "container_cpu_user_seconds_total"),
                        ("system_usec", "container_cpu_system_seconds_total")):
        if key in cpu:
            m.add(metric, "%.6f" % (cpu[key] / 1e6), labels,
                  "CPU time from cpu.stat.", "counter")
    m.add("container_cpu_cfs_throttled_seconds_total",
          "%.6f" % (cpu["throttled_usec"] / 1e6) if "throttled_usec" in cpu
          else None, labels, "Time throttled against the CPU limit.", "counter")
    # No upstream equivalent, and it is the one that explains this host: 92.5%
    # of Jellyfin's CPU was nice_usec, which is why `podman stats` showing it
    # near the top is trickplay extraction rather than anybody watching.
    m.add("home_server_container_cpu_nice_seconds_total",
          "%.6f" % (cpu["nice_usec"] / 1e6) if "nice_usec" in cpu else None,
          labels, "CPU time spent at positive nice.", "counter")

    io = read_kv_io(os.path.join(base, "io.stat"))
    for device, counters in io.items():
        il = dict(labels)
        il["device"] = device
        for key, metric, help_text in (
                ("rbytes", "container_fs_reads_bytes_total",
                 "Bytes read from this device."),
                ("wbytes", "container_fs_writes_bytes_total",
                 "Bytes written to this device."),
                ("rios", "container_fs_reads_total", "Read operations."),
                ("wios", "container_fs_writes_total", "Write operations.")):
            m.add(metric, counters.get(key), il, help_text, "counter")

    m.add("home_server_container_pids", read_int(os.path.join(base,
          "pids.current")), labels, "Processes in the cgroup.")
    m.add("home_server_container_pids_max", read_int(os.path.join(base,
          "pids.max")), labels, "Process limit, absent when unlimited.")


def read_kv_io(path):
    """io.stat: '<major>:<minor> rbytes=N wbytes=N rios=N wios=N ...'.

    Keyed by device number rather than name, because that is what the kernel
    gives and resolving it needs /sys - and the join to node_disk_* is by name.
    The resolution is done here so the label is the same one node-exporter uses.
    """
    out = {}
    try:
        for line in read_text(path).splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            device = _devname(parts[0])
            counters = {}
            for field in parts[1:]:
                if "=" in field:
                    key, _, value = field.partition("=")
                    try:
                        counters[key] = int(value)
                    except ValueError:
                        pass
            if counters:
                out[device] = counters
    except OSError:
        pass
    return out


def _devname(devno):
    try:
        return os.path.basename(os.readlink("/sys/dev/block/%s" % devno))
    except OSError:
        return devno


# ------------------------------------------------------------------------------
# GPU
# ------------------------------------------------------------------------------
# Minted names, deliberately. There is no upstream standard for the field that
# matters most on this host - utilization.encoder - so there is nothing to be
# portable TO, and DCGM's names (SCREAMING_CASE, no unit suffix, framebuffer in
# MiB) would import a contradictory convention permanently.
#
# THE ENGINE IS A LABEL, NOT FOUR METRICS, and that is the point: two NVENC
# sessions pin the encoder block at 100% while the SM sits at 10%, so anyone
# reading utilization.gpu alone sees an idle GPU mid-transcode. Putting them on
# one metric makes reading them side by side the easy query.
#
# NEVER AGGREGATE ACROSS CARDS. GPU 0's video engines are dead hardware - every
# NVENC session on it fails with "unsupported device", which jellyfin.container
# documents - so a sum over both cards reads 50% during a full-rate encode.

GPU_FIELDS = ("index", "uuid", "name", "utilization.gpu", "utilization.memory",
              "utilization.encoder", "utilization.decoder", "memory.total",
              "memory.used", "temperature.gpu", "power.draw", "power.limit",
              "clocks.current.sm", "clocks.current.memory", "fan.speed",
              "encoder.stats.sessionCount", "encoder.stats.averageFps",
              "encoder.stats.averageLatency", "driver_version")


def _num(raw):
    """A CSV cell as a float, or None. nvidia-smi writes [N/A] for a field a
    card does not support, and one unsupported field must drop its own series
    rather than the whole row."""
    try:
        return float(raw.strip())
    except (ValueError, AttributeError):
        return None


def source_gpu(m):
    out = run(["nvidia-smi", "--query-gpu=" + ",".join(GPU_FIELDS),
               "--format=csv,noheader,nounits"], timeout=8)
    if out is None:
        # NOTHING is emitted, never a fabricated zero. A zero here would read as
        # "no transcode running" on a host whose driver has just gone, which is
        # the opposite of the truth and worse than a blank panel. Same doctrine
        # as bin/reboot-when-staged.sh: unknown is not idle.
        raise RuntimeError("nvidia-smi failed")

    for line in out.strip().splitlines():
        f = [c.strip() for c in line.split(",")]
        if len(f) != len(GPU_FIELDS):
            continue
        row = dict(zip(GPU_FIELDS, f))
        labels = {"gpu": row["index"], "uuid": row["uuid"]}

        m.add("home_server_gpu_info", 1,
              {"gpu": row["index"], "uuid": row["uuid"], "name": row["name"],
               "driver_version": row["driver_version"]},
              "GPU identity. The driver version lives here and nowhere else.")

        for field, engine in (("utilization.gpu", "sm"),
                              ("utilization.encoder", "encoder"),
                              ("utilization.decoder", "decoder"),
                              ("utilization.memory", "memory_bandwidth")):
            value = _num(row[field])
            if value is not None:
                el = dict(labels)
                el["engine"] = engine
                m.add("home_server_gpu_utilization_ratio", value / 100.0, el,
                      "Engine utilisation, 0-1. engine=encoder is the one this "
                      "host runs on; engine=sm is near-idle during a transcode "
                      "and reading it alone is misleading. memory_bandwidth is "
                      "time spent moving memory, NOT memory used.")

        for field, metric, scale, help_text in (
                ("memory.used", "home_server_gpu_memory_used_bytes", 1 << 20,
                 "Framebuffer in use, in bytes rather than MiB."),
                ("memory.total", "home_server_gpu_memory_total_bytes", 1 << 20,
                 "Framebuffer size."),
                ("temperature.gpu", "home_server_gpu_temperature_celsius", 1,
                 "Core temperature."),
                ("power.draw", "home_server_gpu_power_watts", 1,
                 "Current board power draw."),
                ("power.limit", "home_server_gpu_power_limit_watts", 1,
                 "Board power cap."),
                ("fan.speed", "home_server_gpu_fan_speed_ratio", 0.01,
                 "Fan speed, 0-1."),
                ("encoder.stats.sessionCount",
                 "home_server_gpu_encoder_sessions", 1,
                 "Active NVENC sessions. The consumer ceiling is 8, but two "
                 "already pin the encoder block at 100%."),
                ("encoder.stats.averageFps", "home_server_gpu_encoder_fps", 1,
                 "Average frames per second across encoder sessions."),
                ("encoder.stats.averageLatency",
                 "home_server_gpu_encoder_latency_seconds", 1e-6,
                 "Average encoder latency, converted from microseconds.")):
            value = _num(row[field])
            if value is not None:
                m.add(metric, value * scale, labels, help_text)

        for field, domain in (("clocks.current.sm", "sm"),
                              ("clocks.current.memory", "memory")):
            value = _num(row[field])
            if value is not None:
                cl = dict(labels)
                cl["domain"] = domain
                m.add("home_server_gpu_clock_hertz", value * 1e6, cl,
                      "Current clock, converted from MHz.")


# ------------------------------------------------------------------------------
# Temperatures
# ------------------------------------------------------------------------------
# Read straight out of sysfs rather than by shelling out to `sensors -j`: no
# fork, and no dependence on lm_sensors' JSON schema staying put.
#
# Minted rather than taking node_exporter's node_hwmon_temp_celsius, because
# that one uses a SLUGIFIED SYSFS PATH as its chip label rather than the chip
# name, and we would not reproduce that faithfully. A name that is almost the
# upstream one is the failure this whole naming rule exists to avoid.

def source_sensors(m):
    found = 0
    for hwmon in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        try:
            chip = read_text(os.path.join(hwmon, "name")).strip()
        except OSError:
            continue
        for path in sorted(glob.glob(os.path.join(hwmon, "temp*_input"))):
            sensor = os.path.basename(path)[:-len("_input")]
            millidegrees = read_int(path)
            if millidegrees is None:
                continue
            labels = {"chip": chip, "sensor": sensor}
            try:
                labels["label"] = read_text(
                    os.path.join(hwmon, sensor + "_label")).strip()
            except OSError:
                labels["label"] = sensor
            m.add("home_server_hwmon_temp_celsius", millidegrees / 1000.0,
                  labels, "Temperature from /sys/class/hwmon.")
            found += 1
    if not found:
        raise RuntimeError("no hwmon temperatures found")


# ------------------------------------------------------------------------------
# Disk health - the SLOW tier
# ------------------------------------------------------------------------------
# -n standby is what stops a monitoring job waking a sleeping spindle every five
# minutes. smartctl exits 2 in that case, which means "asleep" and not "broken";
# run() already returns None on a non-zero exit, so it degrades to no series.

def source_smart(m):
    devices = [d for d in ("/dev/sda", "/dev/nvme0") if os.path.exists(d)]
    if not devices:
        raise RuntimeError("no SMART-capable devices")
    for dev in devices:
        # -i as well as -A -H: without it the JSON carries no model_name or
        # firmware_version and home_server_disk_info comes out with empty
        # labels, which is worse than no info series at all.
        out = run(["sudo", "-n", "smartctl", "-j", "-n", "standby", "-i", "-A",
                   "-H", dev], timeout=20)
        if out is None:
            continue
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            continue
        name = os.path.basename(dev)
        labels = {"device": name}
        m.add("home_server_disk_info", 1,
              {"device": name, "model": data.get("model_name", ""),
               "firmware": data.get("firmware_version", "")},
              "Disk identity. The serial is deliberately not carried.")
        passed = data.get("smart_status", {}).get("passed")
        if passed is not None:
            m.add("home_server_disk_health_ok", 1 if passed else 0, labels,
                  "SMART overall-health self-assessment.")
        temp = data.get("temperature", {}).get("current")
        if temp is not None:
            m.add("home_server_disk_temperature_celsius", temp, labels,
                  "Drive temperature.")
        hours = data.get("power_on_time", {}).get("hours")
        if hours is not None:
            m.add("home_server_disk_power_on_hours", hours, labels,
                  "Powered-on hours.", "counter")
        nvme = data.get("nvme_smart_health_information_log")
        if nvme:
            for key, metric, help_text in (
                    ("percentage_used", "home_server_disk_nvme_wear_ratio",
                     "Endurance consumed, 0-1 where 1 is the rated life."),
                    ("media_errors", "home_server_disk_media_errors_total",
                     "Unrecovered data integrity errors."),
                    ("unsafe_shutdowns", "home_server_disk_unsafe_shutdowns_total",
                     "Power lost without a clean shutdown.")):
                value = nvme.get(key)
                if value is not None:
                    m.add(metric, value / 100.0 if key == "percentage_used"
                          else value, labels, help_text,
                          "gauge" if key == "percentage_used" else "counter")
        for attr in (data.get("ata_smart_attributes", {}).get("table") or []):
            table = {5: ("home_server_disk_reallocated_sectors",
                         "Sectors the drive has remapped."),
                     197: ("home_server_disk_pending_sectors",
                           "Sectors waiting to be remapped - the leading "
                           "indicator of a failing spindle."),
                     199: ("home_server_disk_crc_errors_total",
                           "Interface CRC errors, usually a cable.")}
            entry = table.get(attr.get("id"))
            if entry:
                m.add(entry[0], attr.get("raw", {}).get("value"), labels,
                      entry[1])


# ------------------------------------------------------------------------------
# status.json as series
# ------------------------------------------------------------------------------
# The hourly battery already keys every finding by a stable id. This turns those
# into time series so "when did that start failing" becomes answerable, without
# duplicating the document badly.
#
# THE ORDERED SEVERITY ORDINAL IS THE WHOLE DESIGN. max(home_server_check_status)
# is the entire system's verdict, because the ordering IS the precedence - which
# is the time-series translation of status.json's own guarantee that summary
# .status is one field to colour on and nobody re-derives precedence.
#
# THE MESSAGE IS NEVER EMITTED. Prose is unstable by charter here, and a label
# carrying it would mint a fresh series on every reword and leave the old one
# lingering for the whole retention period. The dashboard fetches the sentence
# from status.json at render time, keyed by the same id it queried with. That is
# the id/prose split, drawn along the boundary between the two stores.

STATUS_FILE = "/var/lib/home-server/status.json"
CHECK_STATUS = {"pass": 0, "note": 1, "warn": 2, "fail": 3}
GREENBOOT_STATES = {"green": 0, "red": 1}
# Facts whose value is a version or a word rather than a number. They become
# labels on one info series, so a new OS version costs one series a month
# instead of one per sample.
FACT_INFO_KEYS = ("booted_version", "staged_version", "driver_version")


def _epoch(stamp):
    try:
        return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError):
        return None


def source_status(m):
    doc = json.loads(read_text(STATUS_FILE))

    for check in doc.get("checks", []):
        value = CHECK_STATUS.get(check.get("status"))
        if value is None:
            continue
        m.add("home_server_check_status", value,
              {"id": check.get("id", ""), "section": check.get("section", "")},
              "0 pass, 1 note, 2 warn, 3 fail. Ordered by severity, so "
              "max() over it is the whole system's verdict and no consumer "
              "re-derives precedence. A check that did not run is ABSENT.")

    m.add("home_server_status_generated_timestamp_seconds",
          _epoch(doc.get("generated_at")), None,
          "When the battery last ran. A TIMESTAMP, not an age: the consumer "
          "subtracts from time(), so a stopped timer shows as staleness rather "
          "than freezing at its last value.")
    m.add("home_server_status_schema", doc.get("schema"), None,
          "status.json's own schema version.")
    for mode, on in (doc.get("mode") or {}).items():
        m.add("home_server_status_mode", 1 if on else 0, {"mode": mode},
              "Which optional sections ran. Absence of a section and a section "
              "that passed must not look alike.")

    facts = doc.get("facts") or {}
    info = {k: str(facts.get(k) or "") for k in FACT_INFO_KEYS}
    m.add("home_server_status_info", 1, info,
          "Version strings from the battery's facts, joined rather than "
          "repeated per sample.")
    m.add("home_server_greenboot_result",
          GREENBOOT_STATES.get(facts.get("greenboot_result")), None,
          "0 green, 1 red. Absent when no verdict has been recorded.")

    for key, value in facts.items():
        if key in FACT_INFO_KEYS or key == "greenboot_result":
            continue
        if value is None:
            # A null fact is ABSENT, never zero. The substrates fail in opposite
            # directions - a JSON key that vanishes makes a reader guess, while
            # a zero in a TSDB reads as a measurement - so the same goal
            # produces opposite encodings, and this is the TSDB's.
            continue
        if isinstance(value, bool):
            m.add("home_server_" + key, 1 if value else 0, None,
                  "From status.json facts.")
        elif isinstance(value, (int, float)):
            # status.json's keys carry their unit in the name - boot_free_mb,
            # uptime_s - which is fine for a JSON document whose keys are the
            # stable interface, and a permanent wart in a metric name. Convert
            # to base units here rather than forking the fact keys, because
            # those are the contract the battery publishes.
            if key.endswith("_mb"):
                m.add("home_server_%s_bytes" % key[:-3], value * (1 << 20),
                      None, "From status.json facts, converted to bytes.")
            elif key.endswith("_s"):
                m.add("home_server_%s_seconds" % key[:-2], value, None,
                      "From status.json facts.")
            else:
                m.add("home_server_" + key, value, None,
                      "From status.json facts.")
        elif key.endswith("_at"):
            m.add("home_server_%s_timestamp_seconds" % key[:-3], _epoch(value),
                  None, "From status.json facts, as a unix timestamp.")


# ------------------------------------------------------------------------------
# The applications - the SLOW tier
# ------------------------------------------------------------------------------
# Every one of these is reached with `podman exec`, which works whatever the
# network topology says and grants NO container any reachability it does not
# already have. That is the established house pattern here, and it is why
# net-arr, net-download, net-media and net-transcode stay sealed from each other
# while all of them can still be measured.
#
# It is also the one place where the diagnostic touches the patient: a poll
# forks a process INSIDE the container being measured. Bounded by the slow tier,
# by curl's own max-time and by a subprocess timeout, in that order.

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
ENV_FILE = os.path.join(REPO, ".env")


def load_env():
    """The .env, read directly rather than through the unit's EnvironmentFile=
    so that --print works from an interactive shell.

    Unlike bin/promote-transcoded.py's loader this DEGRADES rather than dying.
    There is a window during bin/render-env.sh when the file is absent or half
    written, and it must cost the application sources and nothing else - a
    reconciler that stops is safe, a monitor that stops is blind.
    """
    env = {}
    try:
        for line in read_text(ENV_FILE).splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return env


# NOT EVERY IMAGE SHIPS curl, AND THE ONES THAT DO NOT FAILED SILENTLY FOR
# MONTHS. gluetun and jellyseerr carry wget and no curl, so every api_get
# against them returned None - and because each caller guards with
# `if isinstance(x, dict)`, that read as "the endpoint had nothing to say"
# rather than as an error. home_server_vpn_info was therefore NEVER ONCE
# EMITTED since the day it was written: absent from the TSDB, absent from the
# dashboard's VPN row, and reported by nothing, because the source still
# completed and still wrote home_server_collector_source_up 1.
#
# Same shape as the shellcheck leg that printed `all checks passed` over 2,224
# lines it had never read. A client that is missing is not a body that is empty.
CLIENT_UNAVAILABLE = object()

# Containers that answered neither curl nor wget on this run. Emitted as a
# series by main(), because the whole lesson above is that this failure has to
# be visible from outside: a source can lose an endpoint entirely and still
# report source_up 1, since one absent optional call is indistinguishable from
# one that legitimately had nothing to say.
MISSING_CLIENT = set()


def api_get(container, url, headers=None, timeout=12):
    """A GET inside a container, with the credential passed on STDIN not argv.

    `curl -K -` reads its entire configuration from stdin, so an API key never
    appears in the process list - which `podman exec ... -H "X-Api-Key: ..."`
    cannot avoid, and which matters more here than in a job that runs twice an
    hour, because this one runs 288 times a day.

    The wget fallback keeps that property rather than trading it away. wget has
    no config-file equivalent of -K, so the header cannot go in a file - but it
    can be read from stdin by a shell INSIDE the container and expanded there,
    which keeps it out of the host's process list just the same. What it does
    reach is that container's own `ps`, which is the same trust boundary the
    credential is already inside.

    Returns the decoded body, or None. Callers keep their existing
    `if isinstance(x, dict)` guards - what changes is that "this image has no
    HTTP client" now lands in MISSING_CLIENT and on stderr instead of vanishing.
    """
    headers = list(headers or [])
    config = ['url = "%s"' % url, "silent", "max-time = 8"]
    for header in headers:
        config.append('header = "%s"' % header)
    body = _exec_json(container, ["curl", "-K", "-"],
                      "\n".join(config) + "\n", timeout)
    if body is not CLIENT_UNAVAILABLE:
        return body

    # One header is all any caller here passes, and wget's --header can only be
    # given a literal - so the shell reads it and expands it, never argv.
    script = 'read -r h 2>/dev/null; exec wget -q -T 8 -O - --header="$h" "%s"' % url
    body = _exec_json(container, ["sh", "-c", script],
                      (headers[0] if headers else "") + "\n", timeout)
    if body is CLIENT_UNAVAILABLE:
        MISSING_CLIENT.add(container)
        print("collect-metrics: %s has neither curl nor wget; cannot poll %s"
              % (container, url), file=sys.stderr)
        return None
    return body


def _exec_json(container, argv, stdin, timeout):
    """Run argv in a container, decode JSON, and tell the two failures apart.

    A missing executable is exit 127 from the runtime, which is what separates
    "this image has no curl" from "the API refused". Conflating them is the bug
    this function exists to make impossible.
    """
    try:
        res = subprocess.run(["podman", "exec", "-i", container] + argv,
                             input=stdin, capture_output=True,
                             text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return CLIENT_UNAVAILABLE
    if res.returncode == 127 or "executable file" in (res.stderr or ""):
        return CLIENT_UNAVAILABLE
    if res.returncode != 0:
        return None
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        return None


def source_arr(m):
    env = load_env()
    answered = 0

    for name, port in (("sonarr", 8989), ("radarr", 7878)):
        key = env.get("%s_API_KEY" % name.upper(), "")
        if not key:
            continue
        base = "http://localhost:%d/api/v3" % port
        hdr = ["X-Api-Key: " + key]

        status = api_get(name, base + "/queue/status", hdr)
        if isinstance(status, dict):
            answered += 1
            for field, state in (("totalCount", "total"),
                                 ("unknownCount", "unknown")):
                m.add("home_server_arr_queue_items", status.get(field),
                      {"service": name, "state": state},
                      "Items in the download queue.")
            m.add("home_server_arr_queue_errors",
                  1 if status.get("errors") else 0, {"service": name},
                  "The queue is reporting errors.")

        # HOW MANY INDEXERS REACHED THIS APPLICATION, which is a different
        # number from how many Prowlarr has, and the gap is the thing that was
        # invisible. Prowlarr pushes every indexer to every application and
        # retries the ones an application refuses, for ever, six-hourly, at
        # WARN - so a mismatch never surfaces anywhere a person looks. It cost
        # nine months of `Nyaa Trusted - Live Action` returning results in a
        # category neither Sonarr nor Radarr accepts.
        #
        # SOME GAP IS CORRECT and this metric deliberately does not judge:
        # a movies-only indexer belongs in Radarr and not Sonarr. Compare the
        # three series and read the log; do not alert on equality.
        indexers = api_get(name, base + "/indexer", hdr)
        if isinstance(indexers, list):
            m.add("home_server_arr_indexers", len(indexers), {"service": name},
                  "Indexers configured in this application.")

        health = api_get(name, base + "/health", hdr)
        _arr_health(m, name, health)
        if isinstance(health, list):
            answered += 1

    # Prowlarr. THE ONE THAT EARNS ITS KEEP: nothing else in the stack reports
    # that searching has quietly stopped working. Every container stays healthy,
    # every unit stays active, and the only symptom is that nothing is found.
    key = env.get("PROWLARR_API_KEY", "")
    if key:
        hdr = ["X-Api-Key: " + key]
        indexers = api_get("prowlarr", "http://localhost:9696/api/v1/indexer", hdr)
        statuses = api_get("prowlarr",
                           "http://localhost:9696/api/v1/indexerstatus", hdr)
        if isinstance(indexers, list):
            answered += 1
            failing = set()
            if isinstance(statuses, list):
                failing = {s.get("indexerId") for s in statuses
                           if s.get("disabledTill")}
            enabled = 0
            for indexer in indexers:
                if not indexer.get("enable"):
                    continue
                enabled += 1
                m.add("home_server_indexer_up",
                      0 if indexer.get("id") in failing else 1,
                      {"indexer": str(indexer.get("name", "?"))},
                      "0 while Prowlarr is backing off this indexer after "
                      "repeated failures. IT DOES NOT SAY WHY, and the causes "
                      "are not mostly local: measured on 2026-08-15, six zeros "
                      "were a dead mirror, its duplicate, two entries sharing "
                      "one refusing API host, a 502 and a 403. Read the "
                      "Prowlarr log before changing anything here.")
            m.add("home_server_arr_indexers", enabled, {"service": "prowlarr"},
                  "Indexers configured in this application.")
        _arr_health(m, "prowlarr",
                    api_get("prowlarr", "http://localhost:9696/api/v1/health", hdr))

    # Bazarr is NOT a Servarr application: different header, different API.
    key = env.get("BAZARR_API_KEY", "")
    if key:
        hdr = ["X-API-KEY: " + key]
        badges = api_get("bazarr", "http://localhost:6767/api/badges", hdr)
        if isinstance(badges, dict):
            answered += 1
            for field, kind in (("episodes", "episodes"), ("movies", "movies")):
                m.add("home_server_subtitles_missing", badges.get(field),
                      {"kind": kind}, "Items with subtitles still wanted.")

        # NOT `badges.providers`, WHICH COUNTS THE BROKEN ONES. This read
        # `home_server_subtitle_providers` from that field under the help text
        # "providers currently usable", and it was exactly inverted: with one
        # provider enabled and throttled it reported 1, and enabling five more
        # working ones moved it to 2. A wrong number under a right name cannot
        # be spotted from a dashboard, so the field is not used at all now.
        #
        # /api/providers is per-provider and says which. "Good" is Bazarr's own
        # word for usable; every other status - DownloadLimitExceeded, offline,
        # a login failure - is a provider that will not answer.
        providers = api_get("bazarr", "http://localhost:6767/api/providers", hdr)
        rows = providers.get("data") if isinstance(providers, dict) else None
        if isinstance(rows, list):
            answered += 1
            for row in rows:
                m.add("home_server_subtitle_provider_up",
                      1 if str(row.get("status", "")) == "Good" else 0,
                      {"provider": str(row.get("name", "?"))},
                      "0 while this subtitle provider is unusable - most often "
                      "a daily download quota, which is why ONE provider is a "
                      "single point of failure rather than a thin margin.")
            m.add("home_server_subtitle_providers_enabled", len(rows), None,
                  "Subtitle providers enabled, working or not.")

    if not answered:
        raise RuntimeError("no *arr application answered")


def _arr_health(m, service, health):
    """Health issues as a COUNT per severity, never as the message.

    The text is unstable by charter - these are the applications' own strings
    and they get reworded upstream - so a label carrying it would mint a fresh
    series on every release and leave the old one for the whole retention
    period. The count says something is wrong; the UI says what.
    """
    if not isinstance(health, list):
        return
    counts = {}
    for issue in health:
        counts[str(issue.get("type", "unknown")).lower()] = \
            counts.get(str(issue.get("type", "unknown")).lower(), 0) + 1
    for severity in ("error", "warning", "notice"):
        m.add("home_server_arr_health_issues", counts.get(severity, 0),
              {"service": service, "severity": severity},
              "Health issues the application reports, counted by severity.")


def source_jellyfin(m):
    """Jellyfin's CONFIGURATION, which changes rarely and belongs in the slow
    tier. The sessions moved to source_playback: a progress bar needs thirty
    seconds, not five minutes, and a metric name may appear in only one of the
    two .prom files - node-exporter concatenates them and a duplicate sample
    fails the whole scrape.
    """
    env = load_env()
    key = env.get("JELLYFIN_API_KEY", "")
    if not key:
        raise RuntimeError("JELLYFIN_API_KEY is not set")

    # THE FOUR SWITCHES THAT COST 87 HOURS OF CPU DECODE. Trickplay has its OWN
    # hardware-acceleration settings, independent of playback's, and all three
    # of them shipped off - so every frame of every file was decoded on the CPU
    # while playback acceleration looked perfectly healthy. They are on now;
    # this is what notices if any of them goes off again, which a UI toggle or a
    # config restore can do silently.
    encoding = api_get("jellyfin",
                       "http://localhost:8096/System/Configuration/encoding",
                       ["X-Emby-Token: " + key])
    system = api_get("jellyfin", "http://localhost:8096/System/Configuration",
                     ["X-Emby-Token: " + key])
    trickplay = (system or {}).get("TrickplayOptions") or {}
    for feature, value in (
            ("playback_encode", (encoding or {}).get("EnableHardwareEncoding")),
            ("trickplay_decode", trickplay.get("EnableHwAcceleration")),
            ("trickplay_encode", trickplay.get("EnableHwEncoding")),
            ("trickplay_keyframe_only",
             trickplay.get("EnableKeyFrameOnlyExtraction"))):
        if value is not None:
            m.add("home_server_jellyfin_hwaccel_enabled", 1 if value else 0,
                  {"feature": feature},
                  "Hardware acceleration switches. trickplay_* are independent "
                  "of playback's and all three once shipped off, which is what "
                  "made Jellyfin the largest CPU consumer on the host while "
                  "serving nobody. keyframe_only is the big lever.")
    if isinstance(encoding, dict):
        m.add("home_server_jellyfin_hwaccel_info", 1,
              {"type": str(encoding.get("HardwareAccelerationType", ""))},
              "Which hardware acceleration backend is selected.")
        codecs = encoding.get("HardwareDecodingCodecs")
        if isinstance(codecs, list):
            # A COUNT, not a label per codec. Reading this through a
            # line-matching grep is what made it look empty once: the opening
            # and closing tags sit on adjacent lines and hide the children.
            m.add("home_server_jellyfin_hwdecode_codecs", len(codecs), None,
                  "Codecs enabled for hardware decoding.")


def source_torrent(m):
    """qBittorrent needs NO credential from here, and that is not an oversight.

    WebUI\\LocalHostAuth is false, and `podman exec` lands inside the pod's
    network namespace where "localhost" means gluetun, qBittorrent and JOAL and
    nothing else. Proven twice over by things already in this repository: the
    unit's own healthcheck, and gluetun's port-forward push command, both
    unauthenticated. A request arriving over net-download as torrent:8200 is a
    different matter and would need a login.
    """
    env = load_env()
    port = env.get("PORT_QBITTORRENT_WEB", "8200")
    info = api_get("qbittorrent",
                   "http://localhost:%s/api/v2/transfer/info" % port)
    if not isinstance(info, dict):
        raise RuntimeError("qBittorrent did not answer")

    for field, direction in (("dl_info_data", "download"),
                             ("up_info_data", "upload")):
        m.add("home_server_torrent_bytes_total", info.get(field),
              {"direction": direction},
              "Session traffic. Resets when the client restarts, which is what "
              "a counter reset means and Prometheus already handles.", "counter")
    for field, direction in (("dl_info_speed", "download"),
                             ("up_info_speed", "upload")):
        m.add("home_server_torrent_rate_bytes_per_second", info.get(field),
              {"direction": direction}, "Current transfer rate.")
    m.add("home_server_torrent_dht_nodes", info.get("dht_nodes"), None,
          "DHT nodes known.")
    m.add("home_server_torrent_connection_state",
          {"connected": 0, "firewalled": 1}.get(
              str(info.get("connection_status")), 2), None,
          "0 connected, 1 firewalled, 2 disconnected. Firewalled means the "
          "forwarded port and the listen port have drifted apart, which is "
          "silent from every other angle.")

    # THE PORT NUMBER IS THE VALUE, not a label. As a label it would be
    # unbounded - ProtonVPN hands out a different one on every reconnect - and
    # as a value the check that matters is one subtraction.
    prefs = api_get("qbittorrent",
                    "http://localhost:%s/api/v2/app/preferences" % port)
    if isinstance(prefs, dict):
        m.add("home_server_torrent_listen_port", prefs.get("listen_port"), None,
              "The port qBittorrent is listening on. Compare with the port the "
              "VPN is forwarding: if they differ, the client is unconnectable "
              "and nothing else says so.")

    # THE FORWARDED PORT HAS NO READABLE SOURCE HERE, and it is worth writing
    # down why rather than rediscovering it. gluetun writes no port file unless
    # VPN_PORT_FORWARDING_STATUS_FILE is set, which the quadlet does not set,
    # and since v3.40 its control server answers 401 on everything except
    # /v1/publicip/ip - the auth config would be a new secret for one number.
    #
    # What is NOT lost: gluetun pushes the forwarded port into qBittorrent on
    # every reconnect, so home_server_torrent_listen_port above already carries
    # the value that push produced, and home_server_torrent_connection_state
    # reports `firewalled` when the two have drifted - which is the consequence
    # the port number was only ever a proxy for.
    location = api_get("gluetun", "http://127.0.0.1:8000/v1/publicip/ip")
    if isinstance(location, dict):
        # The exit IP is deliberately NOT a label: it changes on every
        # reconnect, so it would mint a new series a day for ever. The region
        # does not, and answers the question actually being asked - is the
        # tunnel up, and is it landing where it should.
        m.add("home_server_vpn_info", 1,
              {"country": str(location.get("country", "")),
               "city": str(location.get("city", "")),
               "organization": str(location.get("organization", ""))},
              "Where the VPN is currently exiting. The tunnel being up at all "
              "is home_server_container_health{container=\"gluetun\"}, which "
              "has a 5s interval because it is the kill-switch.")


def source_tdarr(m):
    """Tdarr's file table is the QUEUE, not a history.

    filejsondb drains to zero by design: every library watches
    library/queued/<type> only, and the flow moves output to transcoded/<type>,
    outside every watched folder - so the folder watcher reaps each file as it
    is promoted. A short table means the queue is empty, which is the goal, and
    that is why this is a GAUGE. The durable history lives in jobsjsondb and is
    deliberately not pulled here: getAll over thousands of rows every five
    minutes would cost more than it tells anyone.
    """
    body = json.dumps({"data": {"collection": "FileJSONDB", "mode": "getAll"}})
    try:
        res = subprocess.run(
            ["podman", "exec", "-i", "tdarr-server", "curl", "-s",
             "--max-time", "10", "-X", "POST",
             "-H", "Content-Type: application/json", "--data-binary", "@-",
             "http://localhost:8266/api/v2/cruddb"],
            input=body, capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("tdarr did not answer")
    if res.returncode != 0:
        raise RuntimeError("tdarr returned %d" % res.returncode)
    rows = json.loads(res.stdout)
    if not isinstance(rows, list):
        raise RuntimeError("unexpected cruddb response")

    verdicts = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        verdict = str(row.get("TranscodeDecisionMaker") or "unknown").lower()
        verdicts[verdict.replace(" ", "_")] = \
            verdicts.get(verdict.replace(" ", "_"), 0) + 1
    for verdict, count in sorted(verdicts.items()):
        m.add("home_server_tdarr_queue_files", count, {"verdict": verdict},
              "Files in Tdarr's library table, by its verdict. A GAUGE, and it "
              "drains to zero by design - a file still here carrying a finished "
              "verdict is one the flow abandoned.")
    m.add("home_server_tdarr_queue_files_total", len(rows), None,
          "Files Tdarr currently has in its library table.")


# ------------------------------------------------------------------------------
# The documents: what is playing, what is in flight, what the library holds
# ------------------------------------------------------------------------------
# Everything below writes a JSON document as well as, or instead of, series.
# Read the DOC_* comment at the top of this file before adding to any of them -
# particularly the part about why a session is not labelled.

TICKS_PER_SECOND = 10_000_000


def _seconds(ticks):
    """Jellyfin counts in 100ns units. The division belongs here, not in the
    browser: a client holding someone else's unit is how a number ends up out by
    a factor of ten million with nothing to catch it."""
    if not isinstance(ticks, (int, float)):
        return None
    return round(ticks / TICKS_PER_SECOND, 3)


def _poster(item):
    """(path, tag) for the dashboard's image proxy, or (None, None).

    The path is bare and the tag is separate so the client can append its own
    maxHeight without having to know whether a `?` is already there. An episode
    borrows its series' poster, because a per-episode image is usually a
    screenshot and reads as noise at 22x32.
    """
    if not isinstance(item, dict):
        return None, None
    tags = item.get("ImageTags") or {}
    if tags.get("Primary") and item.get("Id"):
        return "Items/%s/Images/Primary" % item["Id"], str(tags["Primary"])
    if item.get("SeriesPrimaryImageTag") and item.get("SeriesId"):
        return ("Items/%s/Images/Primary" % item["SeriesId"],
                str(item["SeriesPrimaryImageTag"]))
    return None, None


def _episode_label(item):
    """"S02E05", or the year for a film, or None."""
    if not isinstance(item, dict):
        return None
    if item.get("Type") == "Episode":
        season, number = item.get("ParentIndexNumber"), item.get("IndexNumber")
        if isinstance(season, int) and isinstance(number, int):
            return "S%02dE%02d" % (season, number)
        return str(item.get("SeasonName") or "") or None
    year = item.get("ProductionYear")
    return str(year) if year else None


def source_playback(m, doc):
    """Who is watching what, at thirty-second resolution.

    THE COUNTS CARRY NO IDENTITY AND THE DOCUMENT DOES. That is the whole
    distinction this file is built on: home_server_jellyfin_sessions is a
    400-day series and is therefore labelled by playback method only, because a
    retained record of who watched what is surveillance of the household. The
    document below names titles and devices and is overwritten every thirty
    seconds with no history anywhere. Do not move a field from one to the other
    without re-reading that sentence.
    """
    env = load_env()
    key = env.get("JELLYFIN_API_KEY", "")
    if not key:
        # Note BEFORE raising. `sources` is the contract that keeps "did not
        # answer" distinguishable from "nothing to report", and a source that
        # raises its way out without recording anything breaks exactly that -
        # the key would be absent, which is the one thing the document promises
        # never happens.
        doc.note("jellyfin", False, "JELLYFIN_API_KEY is not set")
        doc.set("sessions", [])
        raise RuntimeError("JELLYFIN_API_KEY is not set")
    sessions = api_get("jellyfin", "http://localhost:8096/Sessions",
                       ["X-Emby-Token: " + key])
    if not isinstance(sessions, list):
        doc.note("jellyfin", False, "sessions did not answer")
        doc.set("sessions", [])
        raise RuntimeError("unexpected /Sessions response")

    methods = {"directplay": 0, "directstream": 0, "transcode": 0}
    playing = []
    for session in sessions:
        item = session.get("NowPlayingItem")
        state = session.get("PlayState") or {}
        if not item:
            continue
        method = str(state.get("PlayMethod") or "").lower()
        methods[method] = methods.get(method, 0) + 1

        # TranscodingInfo is ABSENT ENTIRELY on a direct play, not an empty
        # object - so its presence is the signal and `.get` on a None would
        # raise. UNVERIFIED BRANCH: nothing was transcoding when this was
        # written, so the hardware field below is read defensively and reports
        # null rather than false when it cannot tell. null renders as a plain
        # TRANSCODE badge; false renders as SW TRANSCODE, which is a much
        # stronger claim and must not be made by accident.
        transcoding = session.get("TranscodingInfo")
        hardware = None
        if isinstance(transcoding, dict):
            accel = transcoding.get("HardwareAccelerationType")
            if accel not in (None, ""):
                hardware = str(accel).lower() not in ("none",)
        poster, tag = _poster(item)
        playing.append({
            "id": str(session.get("Id") or item.get("Id") or ""),
            "item_id": str(item.get("Id") or "") or None,
            "title": str(item.get("Name") or "?"),
            "series": str(item.get("SeriesName") or "") or None,
            "sub": _episode_label(item),
            "kind": "series" if item.get("Type") == "Episode" else "movie",
            "user": str(session.get("UserName") or "") or None,
            "client": str(session.get("Client") or "") or None,
            "device": str(session.get("DeviceName") or "") or None,
            # RemoteEndPoint is DELIBERATELY NOT CARRIED. Every session reports
            # Caddy's own net-media address, because everything reaches Jellyfin
            # through the proxy - so a local/remote badge built on it would be
            # confidently wrong for every row, which cannot be spotted from a
            # dashboard. DeviceName and Client are what actually distinguish.
            "method": method or None,
            "hardware": hardware,
            "paused": bool(state.get("IsPaused")),
            "position_s": _seconds(state.get("PositionTicks")),
            "runtime_s": _seconds(item.get("RunTimeTicks")),
            "width": item.get("Width"),
            "height": item.get("Height"),
            "poster": poster,
            "poster_tag": tag,
        })

    for method, count in sorted(methods.items()):
        m.add("home_server_jellyfin_sessions", count,
              {"playback_method": method},
              "Sessions actively playing something. A transcode is the "
              "expensive case and the one worth watching.")
    m.add("home_server_jellyfin_sessions_total", len(sessions), None,
          "Connected sessions, playing or not.")
    doc.set("sessions", playing)
    doc.note("jellyfin", True)


# How an *arr tracked-download state and a qBittorrent state become the one
# vocabulary the dashboard renders. Both maps are exhaustive on purpose: an
# unrecognised value falls through to a named state rather than to nothing, so a
# new upstream string shows up as a row somebody can see instead of a row that
# silently disappears.
ARR_STATES = {
    "downloading": "downloading",
    "importpending": "importing",
    "importing": "importing",
    "importblocked": "error",
    "failedpending": "error",
    "failed": "error",
    "ignored": "queued",
}
QBT_STATES = {
    "downloading": "downloading", "metadl": "downloading",
    "forceddl": "downloading", "alloc": "downloading",
    "stalleddl": "stalled",
    "uploading": "seeding", "forcedup": "seeding",
    "stalledup": "seeding", "queuedup": "seeding",
    "checkingdl": "importing", "checkingup": "importing",
    "checkingresumedata": "importing", "moving": "importing",
    "pauseddl": "queued", "queueddl": "queued", "stoppeddl": "queued",
    "pausedup": "seeding", "stoppedup": "seeding",
    "error": "error", "missingfiles": "error",
}


def source_transfers(m, doc):
    """What is in flight, with a progress bar attached.

    Everything here changes by the second, which is why it is in the fast tier
    while the *arr counts and the Tdarr verdicts stay in the slow one.

    THE *arr QUEUE OWNS AN IN-FLIGHT ITEM AND qBITTORRENT OWNS A SEEDING ONE,
    joined on downloadId, which IS the torrent hash. Without that join the same
    film is two rows - one from each side - for the whole of its download, and
    the design's table is one row per file. The *arr side wins while it is
    tracking, because it is the side that knows the title and why an import
    failed; qBittorrent's row appears once the queue has let go of it.
    """
    env = load_env()
    rows = []
    tracked = set()

    for name, port in (("sonarr", 8989), ("radarr", 7878)):
        key = env.get("%s_API_KEY" % name.upper(), "")
        if not key:
            doc.note(name, False, "no API key")
            continue
        queue = api_get(name, "http://localhost:%d/api/v3/queue"
                        "?pageSize=100&includeMovie=true&includeEpisode=true"
                        % port, ["X-Api-Key: " + key])
        records = queue.get("records") if isinstance(queue, dict) else None
        if not isinstance(records, list):
            doc.note(name, False, "queue did not answer")
            continue
        doc.note(name, True)
        for rec in records:
            if not isinstance(rec, dict):
                continue
            if rec.get("downloadId"):
                tracked.add(str(rec["downloadId"]).lower())
            rows.append(_arr_row(name, rec))

    # Tdarr's WORKERS, not its file table: the table says what a file's verdict
    # was, and only a live worker knows a transcode is running and how far in.
    nodes = api_get("tdarr-server", "http://localhost:8266/api/v2/get-nodes")
    if isinstance(nodes, dict):
        doc.note("tdarr", True)
        for node in nodes.values():
            if not isinstance(node, dict):
                continue
            for worker in (node.get("workers") or {}).values():
                if isinstance(worker, dict):
                    rows.append(_tdarr_row(node, worker))
    else:
        doc.note("tdarr", False, "get-nodes did not answer")

    port = env.get("PORT_QBITTORRENT_WEB", "8200")
    torrents = api_get("qbittorrent",
                       "http://localhost:%s/api/v2/torrents/info" % port)
    if isinstance(torrents, list):
        doc.note("qbittorrent", True)
        states = {}
        for tor in torrents:
            if not isinstance(tor, dict):
                continue
            state = QBT_STATES.get(str(tor.get("state") or "").lower(), "queued")
            states[state] = states.get(state, 0) + 1
            if str(tor.get("hash") or "").lower() in tracked:
                continue
            rows.append(_qbt_row(tor, state))
        for state, count in sorted(states.items()):
            m.add("home_server_torrent_count", count, {"state": state},
                  "Torrents by the state the dashboard groups them under. A "
                  "COUNT, so it is safe to retain - the names are in the "
                  "document, which is not.")
    else:
        doc.note("qbittorrent", False, "torrents did not answer")

    doc.set("transfers", rows)
    counts = {}
    for row in rows:
        counts[row["state"]] = counts.get(row["state"], 0) + 1
    for state, count in sorted(counts.items()):
        m.add("home_server_pipeline_items", count, {"state": state},
              "Items in flight, by pipeline state. The titles are in "
              "activity.json; only the counts are retained.")


def _arr_row(service, rec):
    movie = rec.get("movie") if isinstance(rec.get("movie"), dict) else None
    episode = rec.get("episode") if isinstance(rec.get("episode"), dict) else None
    size = rec.get("size")
    left = rec.get("sizeleft")
    progress = None
    if isinstance(size, (int, float)) and size > 0 and isinstance(left, (int, float)):
        progress = round(max(0.0, min(1.0, 1.0 - left / size)), 4)

    state = ARR_STATES.get(str(rec.get("trackedDownloadState") or "").lower(),
                           "downloading")
    # A warning or error on the tracked status outranks the state: "downloading"
    # with a statusMessage is what a stalled or unimportable item looks like,
    # and reporting it as an ordinary download is how it stays invisible.
    status = str(rec.get("trackedDownloadStatus") or "").lower()
    messages = []
    for entry in (rec.get("statusMessages") or []):
        if isinstance(entry, dict):
            messages.extend(str(x) for x in (entry.get("messages") or []))
    if status == "error":
        state = "error"
    elif status == "warning" and state == "downloading":
        state = "stalled"

    title = None
    if movie:
        title = movie.get("title")
    elif episode:
        title = rec.get("title")
    quality = ((rec.get("quality") or {}).get("quality") or {}).get("name")
    return {
        "id": "%s:queue:%s" % (service, rec.get("id")),
        "title": str(title or rec.get("title") or "?"),
        "sub": (str(movie.get("year")) if movie and movie.get("year")
                else _arr_episode_label(episode)),
        "kind": "movie" if service == "radarr" else "series",
        "state": state,
        "progress": progress,
        "size": size if isinstance(size, (int, float)) else None,
        "rate_bps": None,
        "rate_note": str(rec.get("timeleft") or "") or None,
        "note": (messages[0] if messages else None),
        "source": service,
        "quality": str(quality) if quality else None,
        "poster": None,
        "poster_tag": None,
        "app": service,
        "app_slug": _arr_slug(movie, rec),
        "path": None,
    }


def _arr_episode_label(episode):
    if not isinstance(episode, dict):
        return None
    season, number = episode.get("seasonNumber"), episode.get("episodeNumber")
    if isinstance(season, int) and isinstance(number, int):
        return "S%02dE%02d" % (season, number)
    return None


def _arr_slug(movie, rec):
    """Radarr's titleSlug is the tmdbId as a string; Sonarr's is a real slug.
    Either way it is what the application's own URL takes, so it travels rather
    than being reconstructed in the browser from a guess."""
    if isinstance(movie, dict) and movie.get("titleSlug"):
        return str(movie["titleSlug"])
    series = rec.get("series")
    if isinstance(series, dict) and series.get("titleSlug"):
        return str(series["titleSlug"])
    return None


def _tdarr_row(node, worker):
    path = str(worker.get("file") or "")
    pct = worker.get("percentage")
    fps = worker.get("fps")
    return {
        "id": "tdarr:%s" % (path or worker.get("_id") or "?"),
        "title": os.path.splitext(os.path.basename(path))[0] or "?",
        "sub": None,
        "kind": None,
        "state": "transcoding",
        "progress": (round(max(0.0, min(1.0, float(pct) / 100.0)), 4)
                     if isinstance(pct, (int, float)) else None),
        "size": None,
        "rate_bps": None,
        "rate_note": ("%.0f fps" % fps if isinstance(fps, (int, float)) and fps
                      else str(worker.get("ETA") or "") or None),
        "note": str(node.get("nodeName") or "") or None,
        "source": "tdarr",
        "quality": str(worker.get("outputFileSizeInGbytes") or "") or None,
        "poster": None,
        "poster_tag": None,
        "app": "tdarr",
        "app_slug": None,
        "path": path or None,
    }


def _qbt_row(tor, state):
    progress = tor.get("progress")
    ratio = tor.get("ratio")
    up = tor.get("upspeed")
    down = tor.get("dlspeed")
    rate = down if state in ("downloading", "stalled") else up
    return {
        "id": "qbt:%s" % str(tor.get("hash") or "?"),
        "title": str(tor.get("name") or "?"),
        "sub": None,
        "kind": {"radarr": "movie", "sonarr": "series"}.get(
            str(tor.get("category") or "")),
        "state": state,
        "progress": (round(max(0.0, min(1.0, float(progress))), 4)
                     if isinstance(progress, (int, float)) else None),
        "size": tor.get("size") if isinstance(tor.get("size"), int) else None,
        # ZERO IS A FACT HERE, NOT A MISSING VALUE. A seeding torrent with no
        # peers really is transferring 0 B/s, and collapsing that to null would
        # make it indistinguishable from a rate nobody measured - which is the
        # same distinction format.ts draws by returning "-" for NaN and never
        # for 0. The UI decides whether to show the rate or the ratio; the
        # document just says what is true.
        "rate_bps": rate if isinstance(rate, (int, float)) else None,
        "rate_note": ("ratio %.2f" % ratio
                      if isinstance(ratio, (int, float)) else None),
        "note": str(tor.get("category") or "") or None,
        "source": "qbittorrent",
        "quality": None,
        "poster": None,
        "poster_tag": None,
        "app": "qbittorrent",
        "app_slug": None,
        "path": str(tor.get("content_path") or "") or None,
    }


def source_requests(m, doc):
    """Jellyseerr: the one thing here somebody else is waiting on.

    THE KEY IS READ FROM JELLYSEERR'S OWN CONFIG rather than copied into sops.
    Prowlarr's and Bazarr's keys were read out of their config files once and
    then stored, which is fine for a value nothing regenerates - but Jellyseerr
    writes this one itself, so a stored copy is a second truth that goes stale
    silently the first time it is rotated. config/ is backed up, so nothing is
    lost by reading it where it lives.

    A REQUEST CARRIES NO TITLE, which is the awkward part of this API: only a
    tmdbId. An available request can borrow Jellyfin's copy through
    jellyfinMediaId, but a pending one - exactly the case this panel exists for
    - has no Jellyfin item at all, so its title costs one call to Jellyseerr's
    own TMDB proxy. That is why REQUEST_TITLE_BUDGET exists and why it is
    logged: the panel shows a handful, not all 104.
    """
    settings = os.path.join(REPO, "config", "jellyseerr", "settings.json")
    try:
        key = (json.loads(read_text(settings)).get("main") or {}).get("apiKey")
    except (OSError, ValueError, AttributeError):
        key = None
    if not key:
        doc.note("jellyseerr", False, "no API key in settings.json")
        doc.set("requests", [])
        raise RuntimeError("jellyseerr apiKey unreadable")

    hdr = ["X-Api-Key: " + str(key)]
    base = "http://127.0.0.1:5055/api/v1"
    counts = api_get("jellyseerr", base + "/request/count", hdr)
    if not isinstance(counts, dict):
        doc.note("jellyseerr", False, "request/count did not answer")
        doc.set("requests", [])
        raise RuntimeError("jellyseerr did not answer")

    for field in ("total", "pending", "approved", "processing", "available",
                  "declined"):
        m.add("home_server_requests", counts.get(field), {"status": field},
              "Jellyseerr requests by status. Counts only - the titles live in "
              "library.json, which is not retained.")

    listing = api_get("jellyseerr", base + "/request?take=%d&sort=added"
                      % REQUEST_TITLE_BUDGET, hdr)
    results = listing.get("results") if isinstance(listing, dict) else None
    rows = []
    resolved = 0
    if isinstance(results, list):
        for req in results:
            if not isinstance(req, dict):
                continue
            media = req.get("media") or {}
            kind = "series" if str(req.get("type")) == "tv" else "movie"
            title, year, poster, tag = None, None, None, None

            # An available request has a Jellyfin item, so its poster comes from
            # the same image proxy as everything else. A pending one does not,
            # and Jellyseerr's own /imageproxy answers 400 for every path tried
            # - through its public route too - so there is no second proxy to
            # build. poster stays null and the UI owns the placeholder.
            if media.get("jellyfinMediaId"):
                # No tag, because getting one costs a Jellyfin call per request
                # for three mini-posters. The URL still resolves; it just does
                # not get the long immutable cache a tagged one does, which is
                # the documented behaviour of the proxy rather than a hole in it.
                poster = "Items/%s/Images/Primary" % media["jellyfinMediaId"]

            tmdb = media.get("tmdbId")
            if tmdb and resolved < REQUEST_TITLE_BUDGET:
                path = "/movie/%s" % tmdb if kind == "movie" else "/tv/%s" % tmdb
                detail = api_get("jellyseerr", base + path, hdr)
                resolved += 1
                if isinstance(detail, dict):
                    title = detail.get("title") or detail.get("name")
                    date = str(detail.get("releaseDate")
                               or detail.get("firstAirDate") or "")
                    year = date[:4] or None
            rows.append({
                "id": "jellyseerr:%s" % req.get("id"),
                "title": str(title or "request %s" % req.get("id")),
                "year": year,
                "kind": kind,
                "status": _request_status(req, media),
                "status_code": req.get("status"),
                "media_status_code": media.get("status"),
                "requested_by": str((req.get("requestedBy") or {})
                                    .get("displayName") or "") or None,
                "requested_at": str(req.get("createdAt") or "") or None,
                "poster": poster,
                "poster_tag": tag,
                "jellyfin_id": str(media.get("jellyfinMediaId") or "") or None,
            })
    if isinstance(results, list) and len(results) >= REQUEST_TITLE_BUDGET:
        print("collect-metrics: request list capped at %d of %s"
              % (REQUEST_TITLE_BUDGET, counts.get("total")), file=sys.stderr)

    doc.set("requests", rows)
    doc.set("request_counts", {k: counts.get(k) for k in
                               ("total", "pending", "approved", "processing",
                                "available", "declined")})
    doc.note("jellyseerr", True)


# Jellyseerr's MediaStatus, from its own server/constants/media.ts. Carried as
# BOTH the integer and a derived string: the integer because it is the wire
# value and this mapping is somebody else's to change, the string because a
# dashboard must not hard-code a foreign enum. If they ever disagree, the
# integer is authoritative and this table is the bug.
MEDIA_STATUS = {1: "unknown", 2: "pending", 3: "processing",
                4: "partial", 5: "available"}


def _request_status(req, media):
    if req.get("status") == 1:
        return "pending"
    if req.get("status") == 3:
        return "declined"
    return MEDIA_STATUS.get(media.get("status"), "unknown")


# The two rules below are DUPLICATED FROM bin/promote-transcoded.py, which is
# authoritative and carries the reasoning at length. They are copied rather than
# imported because that script's filename is not importable and its load_env
# deliberately DIES where this one degrades - "a reconciler that stops is safe,
# a monitor that stops is blind" - so a shared module would have to flatten the
# one difference that matters. CHANGE THEM TOGETHER: if the reconciler and the
# dashboard disagree about which files are stuck, the dashboard is wrong.
VIDEO_EXTENSIONS = (".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".m2ts",
                    ".wmv", ".flv", ".webm", ".mpg", ".mpeg", ".vob", ".evo")
TDARR_DONE_VERDICTS = ("Not required", "Transcode success")


def _has_video(directory):
    """True if the directory holds a video file, at any depth.

    IT MUST NOT TEST FOR THE DIRECTORY. Tdarr deletes the video with
    deleteParentFolderIfEmpty, but Radarr and Sonarr leave fanart.jpg,
    poster.jpg and a .nfo behind - so the folder is never empty, never removed,
    and a directory test reports every promoted film as still queued. That
    mistake silently disabled promote-transcoded.py for nine months.
    """
    try:
        for _root, _dirs, files in os.walk(directory):
            for name in files:
                if name.lower().endswith(VIDEO_EXTENSIONS):
                    return True
    except OSError:
        pass
    return False


def source_catalogue(m, doc):
    """What the library holds, what landed recently, and what is stuck.

    The walk over queued/ is metadata only - 70 directories and no file reads -
    which matters because CLAUDE.md measures this spindle losing 45% of its
    throughput to a second concurrent reader. Measured at 0.001 s.
    """
    env = load_env()
    key = env.get("JELLYFIN_API_KEY", "")
    if key:
        hdr = ["X-Emby-Token: " + key]
        counts = api_get("jellyfin", "http://localhost:8096/Items/Counts", hdr)
        if isinstance(counts, dict):
            for field, kind in (("MovieCount", "movies"),
                                ("SeriesCount", "series"),
                                ("EpisodeCount", "episodes")):
                m.add("home_server_library_items", counts.get(field),
                      {"kind": kind}, "Items Jellyfin can see, by kind.")
        latest = api_get("jellyfin",
                         "http://localhost:8096/Items?SortBy=DateCreated"
                         "&SortOrder=Descending&Recursive=true"
                         "&IncludeItemTypes=Movie,Episode&Limit=200"
                         "&Fields=DateCreated,SeriesName,ProductionYear", hdr)
        items = latest.get("Items") if isinstance(latest, dict) else None
        if isinstance(items, list):
            doc.note("jellyfin", True)
            week = now() - 7 * 86400
            recent, done = [], []
            for item in items:
                row = _library_row(item)
                if len(recent) < 12:
                    recent.append(row)
                added = _epoch(str(item.get("DateCreated") or "")[:19] + "Z")
                if added and added >= week:
                    done.append(row)
            doc.set("recently_added", recent)
            doc.set("recently_added_total", len(done))
            doc.set("done", done[:120])
            m.add("home_server_library_added_7d", len(done), None,
                  "Items Jellyfin first saw in the last seven days.")
        else:
            doc.note("jellyfin", False, "item list did not answer")
    else:
        doc.note("jellyfin", False, "JELLYFIN_API_KEY is not set")

    _library_sizes(m, env, doc)
    doc.set("attention", _attention_rows(m, doc))
    doc.set("totals", _subtitle_totals(m, env, doc))


def _subtitle_totals(m, env, doc):
    """The subtitle backlog, per ITEM - which is not the number already on the
    dashboard, and the difference is not a bug in either.

    home_server_subtitles_missing comes from Bazarr's badges and counts missing
    subtitle FILES: 1,038. This counts EPISODES with at least one missing
    subtitle: 543. Most episodes here want both English and French, so
    543 x ~2 ~= 1,038. Two different questions, so two different names - a
    second series called subtitles_missing_something would be indistinguishable
    from the first on a dashboard, which is the mistake
    home_server_container_memory_high_bytes exists to avoid.
    """
    totals = {"no_subtitle_episodes": None, "no_subtitle_movies": None}
    key = env.get("BAZARR_API_KEY", "")
    if not key:
        doc.note("bazarr", False, "no API key")
        return totals
    hdr = ["X-API-KEY: " + key]
    answered = False
    for path, field, kind in (("episodes", "no_subtitle_episodes", "episodes"),
                              ("movies", "no_subtitle_movies", "movies")):
        wanted = api_get("bazarr",
                         "http://localhost:6767/api/%s/wanted?length=1" % path,
                         hdr)
        if isinstance(wanted, dict) and isinstance(wanted.get("total"), int):
            answered = True
            totals[field] = wanted["total"]
            m.add("home_server_subtitles_wanted_items", wanted["total"],
                  {"kind": kind},
                  "Items with at least one missing subtitle. NOT the same as "
                  "home_server_subtitles_missing, which counts missing subtitle "
                  "FILES - most episodes here want two languages, so that "
                  "number is roughly twice this one.")
    doc.note("bazarr", answered, None if answered else "wanted did not answer")
    return totals


def _library_row(item):
    poster, tag = _poster(item)
    return {
        "id": "jf:%s" % item.get("Id"),
        "item_id": str(item.get("Id") or "") or None,
        "title": str(item.get("SeriesName") or item.get("Name") or "?"),
        "sub": _episode_label(item),
        "kind": "series" if item.get("Type") == "Episode" else "movie",
        "state": "done",
        "progress": 1.0,
        "size": None,
        "rate_bps": None,
        "rate_note": None,
        "note": None,
        "source": "jellyfin",
        "quality": None,
        "poster": poster,
        "poster_tag": tag,
        "app": "jellyfin",
        "app_slug": None,
        "added_at": str(item.get("DateCreated") or "") or None,
        "path": None,
    }


def _library_sizes(m, env, doc):
    """Bytes and items per library, from the *arr records rather than from du.

    A `du` over 7.3 TB on a 7200rpm spindle is minutes of head travel for a
    number both applications already hold exactly. The root folder is what
    distinguishes the four libraries, and queued/ against transcoded/ is what
    distinguishes "waiting" from "served".
    """
    for name, port, path in (("radarr", 7878, "/api/v3/movie"),
                             ("sonarr", 8989, "/api/v3/series")):
        key = env.get("%s_API_KEY" % name.upper(), "")
        if not key:
            doc.note(name, False, "no API key")
            continue
        records = api_get(name, "http://localhost:%d%s" % (port, path),
                          ["X-Api-Key: " + key])
        if not isinstance(records, list):
            doc.note(name, False, "library list did not answer")
            continue
        doc.note(name, True)
        items, sizes, files = {}, {}, {}
        for rec in records:
            if not isinstance(rec, dict):
                continue
            root = str(rec.get("rootFolderPath") or "").rstrip("/")
            label = root.rsplit("/", 1)[-1] or "?"
            stage = "transcoded" if "/transcoded/" in root + "/" else "queued"
            bucket = (label, stage)
            items[bucket] = items.get(bucket, 0) + 1
            stats = rec.get("statistics") or {}
            sizes[bucket] = sizes.get(bucket, 0) + (
                stats.get("sizeOnDisk") or rec.get("sizeOnDisk") or 0)
            files[bucket] = files.get(bucket, 0) + (
                stats.get("episodeFileCount")
                or (1 if rec.get("hasFile") else 0))
        for (label, stage), count in sorted(items.items()):
            labels = {"library": label, "stage": stage}
            m.add("home_server_library_records", count, labels,
                  "Records the *arr application holds for this library and "
                  "stage. A record with no file is a wanted item, not a file.")
            m.add("home_server_library_files", files.get((label, stage), 0),
                  labels, "Media files present for this library and stage.")
            m.add("home_server_library_bytes", sizes.get((label, stage), 0),
                  labels, "Bytes on disk, as the *arr application accounts for "
                  "them. Not a du - see _library_sizes.")


def _attention_rows(m, doc):
    """Files that are stuck, and the difference between stuck and patient.

    `gone=False, arrived=False` is what a live transcode looks like AND what an
    abandoned one looks like, which is why promote-transcoded.py used to report
    an abandoned file as "waiting on Tdarr" for ever. A file still sitting in
    queued/ with its video intact, against which Tdarr has already recorded a
    finished verdict, is one the flow gave up on - and that is the one finding
    on this page that nothing else in the stack surfaces.
    """
    finished = set()
    body = json.dumps({"data": {"collection": "FileJSONDB", "mode": "getAll"}})
    try:
        res = subprocess.run(
            ["podman", "exec", "-i", "tdarr-server", "curl", "-s",
             "--max-time", "10", "-X", "POST",
             "-H", "Content-Type: application/json", "--data-binary", "@-",
             "http://localhost:8266/api/v2/cruddb"],
            input=body, capture_output=True, text=True, timeout=20, check=False)
        rows = json.loads(res.stdout) if res.returncode == 0 else None
        if isinstance(rows, list):
            for row in rows:
                if (isinstance(row, dict)
                        and str(row.get("TranscodeDecisionMaker") or "")
                        in TDARR_DONE_VERDICTS):
                    finished.add(str(row.get("file") or ""))
    except (OSError, subprocess.SubprocessError, ValueError):
        pass

    out = []
    stalled = queued = 0
    for kind in MEDIA_TYPES:
        root = os.path.join(MEDIA_HOST, "queued", kind)
        try:
            entries = sorted(os.scandir(root), key=lambda e: e.name)
        except OSError:
            continue
        for entry in entries:
            if not entry.is_dir() or not _has_video(entry.path):
                continue
            tdarr_path = entry.path.replace(MEDIA_HOST, MEDIA_TDARR, 1)
            abandoned = any(p.startswith(tdarr_path) for p in finished)
            stalled += 1 if abandoned else 0
            queued += 0 if abandoned else 1
            out.append({
                "id": "queued:%s" % entry.path,
                "title": entry.name,
                "sub": None,
                "kind": "movie" if kind in ("movies", "documentaries") else "series",
                "state": "stalled" if abandoned else "queued",
                "progress": None,
                "size": None,
                "rate_bps": None,
                "rate_note": None,
                "note": ("Tdarr recorded a finished verdict and the file is "
                         "still here" if abandoned else None),
                "source": "tdarr" if abandoned else "filesystem",
                "quality": None,
                "poster": None,
                "poster_tag": None,
                "app": "tdarr" if abandoned else None,
                "app_slug": None,
                "path": entry.path,
            })
    m.add("home_server_pipeline_stalled", stalled, None,
          "Files in queued/ against which Tdarr has recorded a finished "
          "verdict - i.e. the flow abandoned them. Derived the same way "
          "bin/promote-transcoded.py derives STUCK; if the two disagree, this "
          "one is wrong.")
    m.add("home_server_pipeline_queued", queued, None,
          "Files in queued/ still waiting for Tdarr. Zero is the healthy "
          "steady state, not a fault.")
    doc.note("filesystem", True)
    return out


# ------------------------------------------------------------------------------
# The collector's own record
# ------------------------------------------------------------------------------
# There is deliberately no home_server_collector_up 1. A sample asserting
# liveness can only be written by something that is alive, so it is a tautology
# that reads green for ever after this stops running. The timestamp below is
# written INTO the file this run produces: if the run fails the file is not
# replaced, so the last value present is by construction the last success - and
# node_textfile_mtime_seconds says the same thing from outside.

# (name, function, slow). A slow source runs every 5 minutes rather than every
# tick, because its cost is real: smartctl talks to the drive, and the
# application sources fork a process inside the container being measured.
#
# Tier selection is `int(time.time()) % 300 < 30` - wall-clock modulo, so it is
# stateless, cannot drift, and cannot get stuck. A slow round lost to a skipped
# tick is picked up five minutes later.
#
# SLOW SOURCES WRITE THEIR OWN FILE, and that is not tidiness. The textfile is
# rewritten whole on every run, so if the slow series were in it they would
# vanish for nine ticks out of ten and reappear on the tenth - a sawtooth of
# gaps that looks exactly like a flapping disk. node-exporter globs *.prom, so a
# second file is simply served unchanged in between.
# (name, function, slow, document). The fourth field is which document the
# source writes into, and a source that writes one is called with (m, doc)
# instead of (m) - the two call shapes are worth the little ugliness in main()
# because the alternative is threading an unused argument through the seven
# sources that produce no document at all.
#
# THE FAST TIER GAINED TWO APPLICATION SOURCES, WHICH BREAKS THE OLD RULE THAT
# APPLICATION POLLS ARE SLOW, and the reason is worth stating: the slow tier is
# five minutes, and a progress bar five minutes out of date is not stale, it is
# wrong. Both new sources are progress - a playback position and a download
# percentage - so they go where the resolution is. Measured cost: one
# `podman exec ... curl` is about 0.12 s, these add five, and the whole fast
# tier was 0.114 s against a 30 s budget.
SOURCES = (
    ("filesystems", source_filesystems, False, None),
    ("network", source_network, False, None),
    ("containers", source_containers, False, None),
    ("gpu", source_gpu, False, None),
    ("sensors", source_sensors, False, None),
    ("status", source_status, False, None),
    ("playback", source_playback, False, "activity"),
    ("transfers", source_transfers, False, "activity"),
    ("smart", source_smart, True, None),
    ("arr", source_arr, True, None),
    ("jellyfin", source_jellyfin, True, None),
    ("torrent", source_torrent, True, None),
    ("tdarr", source_tdarr, True, None),
    ("requests", source_requests, True, "library"),
    ("catalogue", source_catalogue, True, "library"),
)


def write_textfile(path, body):
    """Atomic replace. os.replace cannot be interrupted halfway within one
    filesystem, and node-exporter globs *.prom - so the .tmp is never read and a
    reader never sees a partial file."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="ascii") as fh:
            fh.write(body)
        os.replace(tmp, path)
        return True
    except OSError as exc:
        print("collect-metrics: cannot write %s: %s" % (path, exc),
              file=sys.stderr)
        return False


def write_document(path, body):
    """Atomic replace, with the .tmp INSIDE the served directory.

    THAT IS NOT A DETAIL. The dashboard container reads this over a rootless
    bind mount, so the file has to be container_file_t - which it gets by being
    CREATED in a directory that already is. A file written to /tmp and renamed
    in keeps tmp_t, and the container gets permission denied on something that
    looks perfectly ordinary from the host. Same trap status.json's second copy
    documents, from the other direction.
    """
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="ascii") as fh:
            fh.write(body)
        os.replace(tmp, path)
        return True
    except OSError as exc:
        print("collect-metrics: cannot write %s: %s" % (path, exc),
              file=sys.stderr)
        return False


def write_marker(ok, started, duration, failed, series):
    """key=value, ISO-8601 UTC, tmp+mv - the backup-state convention exactly.

    last_ok_at only advances on a successful run, so "failing since Tuesday" and
    "has never once run" do not look alike.
    """
    previous = {}
    try:
        for line in read_text(MARKER).splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                previous[key] = value
    except OSError:
        pass
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))
    state = {
        "last_run_at": stamp,
        "last_ok_at": stamp if ok else previous.get("last_ok_at", ""),
        "sources_failed": ",".join(failed),
        "series": str(series),
        "collect_seconds": "%.3f" % duration,
    }
    body = "".join("%s=%s\n" % kv for kv in sorted(state.items()))
    try:
        os.makedirs(os.path.dirname(MARKER), exist_ok=True)
        tmp = MARKER + ".tmp"
        with open(tmp, "w", encoding="ascii") as fh:
            fh.write(body)
        os.replace(tmp, MARKER)
    except OSError as exc:
        print("collect-metrics: cannot write %s: %s" % (MARKER, exc),
              file=sys.stderr)


def _doc_path(key):
    return DOC_ACTIVITY if key == "activity" else DOC_LIBRARY


def main():
    only = None
    to_stdout = "--print" in sys.argv
    if "--source" in sys.argv:
        idx = sys.argv.index("--source")
        if idx + 1 < len(sys.argv):
            only = sys.argv[idx + 1]

    started = now()
    # Forced with --slow or --source, so a slow source is testable by hand
    # without waiting up to five minutes for its turn to come round.
    slow_due = ("--slow" in sys.argv or only is not None
                or int(started) % 300 < 30)

    m = Metrics()
    slow = Metrics()
    docs = {"activity": Document(), "library": Document()}
    wrote_doc = set()
    failed = []
    for name, fn, is_slow, doc_key in SOURCES:
        if only and name != only:
            continue
        if is_slow and not slow_due:
            continue
        target = slow if is_slow else m
        t0 = now()
        try:
            if doc_key:
                fn(target, docs[doc_key])
                wrote_doc.add(doc_key)
            else:
                fn(target)
            up = 1
        except Exception as exc:  # noqa: BLE001 - one source must not stop the rest
            up = 0
            failed.append(name)
            print("collect-metrics: source %s failed: %s" % (name, exc),
                  file=sys.stderr)
            # A DOCUMENT SOURCE THAT RAISED STILL COUNTS AS HAVING WRITTEN.
            # It has already called doc.note(..., False) on its way down, so the
            # document goes out saying which upstream did not answer - which is
            # the entire reason `sources` exists. Skipping the write here would
            # leave the previous file in place and the page would render a dead
            # application as fresh data.
            if doc_key:
                wrote_doc.add(doc_key)
        target.add("home_server_collector_source_up", up, {"source": name},
                   "1 when this source produced its series on the last run.")
        target.add("home_server_collector_source_duration_seconds",
                   "%.4f" % (now() - t0), {"source": name},
                   "Wall time for this source.")

    duration = now() - started
    m.add("home_server_collector_last_success_timestamp_seconds",
          "%.3f" % started if not failed else None, None,
          "When this collector last completed every source. A TIMESTAMP, not "
          "an age: an age gauge freezes at its last value and reads '30 seconds "
          "old' for ever after the collector dies.")
    m.add("home_server_collector_duration_seconds", "%.4f" % duration, None,
          "Wall time for the whole run.")
    # Zero is written explicitly rather than omitted, because this series exists
    # precisely to catch a silent absence and a series that is only present when
    # something is wrong cannot be alerted on with `== 0` or graphed as healthy.
    m.add("home_server_collector_client_unavailable", len(MISSING_CLIENT), None,
          "Containers that answered neither curl nor wget, so an application "
          "endpoint could not be polled at all. This is NOT the same as an "
          "endpoint with nothing to report, and conflating them hid "
          "home_server_vpn_info's total absence for months.")
    m.add("home_server_collector_series", m.count + slow.count + 1, None,
          "Series written last run. A source that silently stops emitting a "
          "sub-family looks identical to one emitting legitimate absence; a "
          "count catches it.")

    if to_stdout:
        sys.stdout.write(m.render())
        if slow.count:
            sys.stdout.write(slow.render())
        for key in sorted(wrote_doc):
            sys.stdout.write("# %s\n%s" % (os.path.basename(_doc_path(key)),
                                           docs[key].render(started)))
    else:
        if not write_textfile(TEXTFILE, m.render()):
            failed.append("write")
        # Only rewritten when the slow tier actually ran. Left alone otherwise,
        # so node-exporter keeps serving the previous values instead of the
        # series blinking out for nine ticks in ten.
        if slow.count and not write_textfile(TEXTFILE_SLOW, slow.render()):
            failed.append("write_slow")
            failed.append("write")
        # Same rule for the documents, and for the same reason: the slow one is
        # left alone on a fast-only tick rather than rewritten empty. Its own
        # generated_at is what tells the page how old it is, so a carried-forward
        # file cannot read as current.
        for key in sorted(wrote_doc):
            if not write_document(_doc_path(key), docs[key].render(started)):
                failed.append("write_%s" % key)

    write_marker(not failed, started, duration, failed, m.count)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
