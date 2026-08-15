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


def api_get(container, url, headers=None, timeout=12):
    """A GET inside a container, with the credential passed on STDIN not argv.

    `curl -K -` reads its entire configuration from stdin, so an API key never
    appears in the process list - which `podman exec ... -H "X-Api-Key: ..."`
    cannot avoid, and which matters more here than in a job that runs twice an
    hour, because this one runs 288 times a day.
    """
    config = ['url = "%s"' % url, "silent", "max-time = 8"]
    for header in (headers or []):
        config.append('header = "%s"' % header)
    try:
        res = subprocess.run(["podman", "exec", "-i", container, "curl", "-K", "-"],
                             input="\n".join(config) + "\n", capture_output=True,
                             text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
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
    env = load_env()
    key = env.get("JELLYFIN_API_KEY", "")
    if not key:
        raise RuntimeError("JELLYFIN_API_KEY is not set")
    sessions = api_get("jellyfin", "http://localhost:8096/Sessions",
                       ["X-Emby-Token: " + key])
    if not isinstance(sessions, list):
        raise RuntimeError("unexpected /Sessions response")

    # NO user, device or item label. They are unbounded in principle, and they
    # are surveillance of the household - what is wanted is how hard the box is
    # working, which the playback method answers on its own.
    methods = {"directplay": 0, "directstream": 0, "transcode": 0}
    for session in sessions:
        if not session.get("NowPlayingItem"):
            continue
        method = str((session.get("PlayState") or {}).get("PlayMethod") or "")
        methods[method.lower()] = methods.get(method.lower(), 0) + 1
    for method, count in sorted(methods.items()):
        m.add("home_server_jellyfin_sessions", count,
              {"playback_method": method},
              "Sessions actively playing something. A transcode is the "
              "expensive case and the one worth watching.")
    m.add("home_server_jellyfin_sessions_total", len(sessions), None,
          "Connected sessions, playing or not.")

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
SOURCES = (
    ("filesystems", source_filesystems, False),
    ("network", source_network, False),
    ("containers", source_containers, False),
    ("gpu", source_gpu, False),
    ("sensors", source_sensors, False),
    ("status", source_status, False),
    ("smart", source_smart, True),
    ("arr", source_arr, True),
    ("jellyfin", source_jellyfin, True),
    ("torrent", source_torrent, True),
    ("tdarr", source_tdarr, True),
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
    failed = []
    for name, fn, is_slow in SOURCES:
        if only and name != only:
            continue
        if is_slow and not slow_due:
            continue
        target = slow if is_slow else m
        t0 = now()
        try:
            fn(target)
            up = 1
        except Exception as exc:  # noqa: BLE001 - one source must not stop the rest
            up = 0
            failed.append(name)
            print("collect-metrics: source %s failed: %s" % (name, exc),
                  file=sys.stderr)
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
    m.add("home_server_collector_series", m.count + slow.count + 1, None,
          "Series written last run. A source that silently stops emitting a "
          "sub-family looks identical to one emitting legitimate absence; a "
          "count catches it.")

    if to_stdout:
        sys.stdout.write(m.render())
        if slow.count:
            sys.stdout.write(slow.render())
    else:
        if not write_textfile(TEXTFILE, m.render()):
            failed.append("write")
        # Only rewritten when the slow tier actually ran. Left alone otherwise,
        # so node-exporter keeps serving the previous values instead of the
        # series blinking out for nine ticks in ten.
        if slow.count and not write_textfile(TEXTFILE_SLOW, slow.render()):
            failed.append("write_slow")
            failed.append("write")

    write_marker(not failed, started, duration, failed, m.count)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
