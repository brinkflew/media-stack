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
# A DIAGNOSTIC MUST NEVER BREAK THE THING IT ANNOTATES. Every source is called
# inside its own try/except with a subprocess timeout; one that fails drops its
# own series, records itself in home_server_collector_source_up, and changes
# nothing else. The file is written atomically, so a reader never sees half of
# one. This script writes nowhere except that file and its own marker.
#
# Usage:
#   bin/collect-metrics.py            collect and write   (what the timer runs)
#   bin/collect-metrics.py --print    collect, print to stdout, write nothing
#   bin/collect-metrics.py --source containers   one source only
# ==============================================================================

import json
import os
import subprocess
import sys
import time

CACHE = os.environ.get("DOCKER_VOLUME_CACHE", "/var/home-server/cache")
TEXTFILE = os.path.join(CACHE, "textfile", "home-server.prom")
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
        m.add("home_server_container_start_time_seconds",
              _started_at(c), labels,
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
    for key, metric, help_text in (
            ("anon", "anon_bytes", "Anonymous memory - the actual working set."),
            ("file", "file_bytes", "Page cache charged to this cgroup."),
            ("inactive_file", "inactive_file_bytes",
             "Cold, clean page cache. Reclaimable at essentially no cost, and "
             "the difference between 'at its ceiling' and 'in trouble'."),
            ("active_file", "active_file_bytes", "Recently used page cache.")):
        m.add("home_server_container_memory_" + metric, stat.get(key), labels,
              help_text)
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

    m.add("home_server_container_memory_current_bytes",
          read_int(os.path.join(base, "memory.current")), labels,
          "memory.current. MISLEADING ON ITS OWN - read it beside anon and "
          "pressure, never instead of them.")
    m.add("home_server_container_memory_peak_bytes",
          read_int(os.path.join(base, "memory.peak")), labels,
          "High-water mark since the cgroup was created.")
    m.add("home_server_container_memory_high_bytes",
          read_int(os.path.join(base, "memory.high")), labels,
          "The MemoryHigh= throttle watermark. NOT memory.low, which is what "
          "cAdvisor's reservation_limit metric reports.")
    m.add("home_server_container_memory_max_bytes",
          read_int(os.path.join(base, "memory.max")), labels,
          "The MemoryMax= hard limit.")

    events = read_kv(os.path.join(base, "memory.events"))
    for key in ("high", "max", "oom", "oom_kill"):
        if key in events:
            ev = dict(labels)
            ev["event"] = key
            m.add("home_server_container_memory_events_total", events[key], ev,
                  "memory.events. `high` on its own proves NOTHING - a cgroup "
                  "doing file I/O always accumulates it. `oom_kill` is the one "
                  "that is unambiguous.", "counter")

    for controller in ("cpu", "memory", "io"):
        for level, seconds in read_pressure(
                os.path.join(base, "%s.pressure" % controller)).items():
            pl = dict(labels)
            pl["level"] = level
            m.add("home_server_container_%s_pressure_stall_seconds_total"
                  % controller, "%.6f" % seconds, pl,
                  "PSI total stall. The arbiter: real starvation shows here, "
                  "and a cgroup merely holding cache does not.", "counter")

    cpu = read_kv(os.path.join(base, "cpu.stat"))
    for key, metric in (("usage_usec", "usage"), ("user_usec", "user"),
                        ("system_usec", "system"), ("nice_usec", "nice")):
        if key in cpu:
            m.add("home_server_container_cpu_%s_seconds_total" % metric,
                  "%.6f" % (cpu[key] / 1e6), labels,
                  "CPU time. nice_usec is why `podman stats` showing Jellyfin "
                  "near the top is trickplay, not usage.", "counter")
    m.add("home_server_container_cpu_throttled_seconds_total",
          "%.6f" % (cpu["throttled_usec"] / 1e6) if "throttled_usec" in cpu
          else None, labels, "Time throttled against the CPU limit.", "counter")

    io = read_kv_io(os.path.join(base, "io.stat"))
    for device, counters in io.items():
        il = dict(labels)
        il["device"] = device
        for key, metric, help_text in (
                ("rbytes", "read_bytes_total", "Bytes read from this device."),
                ("wbytes", "write_bytes_total", "Bytes written to this device."),
                ("rios", "reads_total", "Read operations."),
                ("wios", "writes_total", "Write operations.")):
            m.add("home_server_container_io_" + metric, counters.get(key), il,
                  help_text, "counter")

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
# The collector's own record
# ------------------------------------------------------------------------------
# There is deliberately no home_server_collector_up 1. A sample asserting
# liveness can only be written by something that is alive, so it is a tautology
# that reads green for ever after this stops running. The timestamp below is
# written INTO the file this run produces: if the run fails the file is not
# replaced, so the last value present is by construction the last success - and
# node_textfile_mtime_seconds says the same thing from outside.

SOURCES = (
    ("filesystems", source_filesystems),
    ("network", source_network),
    ("containers", source_containers),
)


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
    m = Metrics()
    failed = []
    for name, fn in SOURCES:
        if only and name != only:
            continue
        t0 = now()
        try:
            fn(m)
            up = 1
        except Exception as exc:  # noqa: BLE001 - one source must not stop the rest
            up = 0
            failed.append(name)
            print("collect-metrics: source %s failed: %s" % (name, exc),
                  file=sys.stderr)
        m.add("home_server_collector_source_up", up, {"source": name},
              "1 when this source produced its series on the last run.")
        m.add("home_server_collector_source_duration_seconds",
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
    m.add("home_server_collector_series", m.count + 1, None,
          "Series written last run. A source that silently stops emitting a "
          "sub-family looks identical to one emitting legitimate absence; a "
          "count catches it.")

    body = m.render()
    if to_stdout:
        sys.stdout.write(body)
    else:
        try:
            os.makedirs(os.path.dirname(TEXTFILE), exist_ok=True)
            tmp = TEXTFILE + ".tmp"
            with open(tmp, "w", encoding="ascii") as fh:
                fh.write(body)
            # os.replace is atomic within a filesystem, and node-exporter globs
            # *.prom - so the .tmp is never read and a reader never sees a
            # half-written file.
            os.replace(tmp, TEXTFILE)
        except OSError as exc:
            print("collect-metrics: cannot write %s: %s" % (TEXTFILE, exc),
                  file=sys.stderr)
            failed.append("write")

    write_marker(not failed, started, duration, failed, m.count)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
