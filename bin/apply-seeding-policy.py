#!/usr/bin/env python3
# ==============================================================================
# Seed for at least 72 hours, then stop at ratio 1.5 or one week
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, from a systemd user timer. See host/systemd/.
#
# THE POLICY, and which half of it qBittorrent can express on its own:
#
#     seed for AT LEAST 72 hours,
#     then stop at ratio 1.5 or 7 days of seeding, whichever comes first.
#
# The second line is native. qBittorrent evaluates a ratio limit and a seeding
# time limit together and stops on whichever is reached first, so "1.5 or a
# week" needs no code at all.
#
# THE FLOOR IS THE PART THAT NEEDS THIS SCRIPT. Every share limit qBittorrent
# has is a MAXIMUM that triggers an action; there is no minimum-seed-time
# setting anywhere in it. So the floor cannot be configured, only enforced - by
# withholding the limits until a torrent has earned them, which is all this
# script does.
#
# It matters in exactly one case, and that case is the common one for a popular
# release: a torrent that reaches ratio 1.5 in under three days. The seven-day
# limit can never fire before 72 hours, so the ratio limit is the only way the
# floor can be breached.
#
# WHY THE GLOBAL LIMITS MUST BE OFF, which is the load-bearing half. A
# per-torrent limit of -2 means "use the global one". A brand new torrent starts
# at -2, so if the global limits are enabled it inherits them the moment it
# completes and can be stopped - and therefore deleted - hours into its life,
# with this script none the wiser. Turning them off is what makes the DEFAULT
# state safe, and this script asserts it on every run rather than trusting that
# nobody has touched the UI.
#
# Young torrents are additionally pinned to an explicit -1 (no limit) rather
# than left at -2. Belt and braces: -2 is only as safe as the global setting it
# defers to, and -1 is safe whatever happens to that setting.
#
# THIS SCRIPT DELETES NOTHING, AND DOES NOT NEED TO. Radarr and Sonarr both run
# with removeCompletedDownloads, and they remove the torrent AND its files once
# the client reports it done seeding. They still track torrents imported months
# ago - verified against Radarr's history API, which still holds `grabbed` and
# `downloadFolderImported` for a film grabbed in November 2025 - so an old
# torrent being stopped here is still reaped by the application that grabbed it.
# The queue endpoint not listing it is not evidence to the contrary; the queue
# only shows items that are downloading or waiting to import.
#
# That split is worth keeping. Deletion stays with the two applications that
# know whether a file was ever imported, and this script's blast radius stays at
# "set a number on a torrent".
#
# IT FAILS IN THE SAFE DIRECTION. If the timer stops, no torrent is ever
# promoted out of the holding state, so nothing is stopped and nothing is
# deleted - the library keeps seeding and the disk grows. The opposite design,
# where a dead script means files get deleted early, would put the tracker
# account at risk every time this host went down. bin/verify-host.sh reads the
# marker written at the end of this file so a stalled timer is visible.
#
# WHY IT RUNS ON THE HOST rather than in a container: `podman exec` lands inside
# the torrent pod's network namespace, where "localhost" is gluetun, qBittorrent
# and JOAL and nothing else. That needs no credential, because
# WebUI\LocalHostAuth is false, and it grants no container any reachability it
# did not already have. Same argument as bin/promote-transcoded.py.
#
# Usage:  bin/apply-seeding-policy.py [--dry-run] [--verbose]
# ==============================================================================

import argparse
import json
import os
import subprocess
import sys
import time

# Derived from this file's own location rather than hardcoded, so moving the
# checkout does not silently point this at an .env that is not there.
REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
ENV_FILE = os.path.join(REPO, ".env")
MARKER = os.path.expanduser("~/.cache/home-server/seeding-state")

CONTAINER = "qbittorrent"

# THE POLICY, as three numbers. They are constants rather than .env variables on
# purpose: they are a decision about how this house treats a tracker, not a
# deployment parameter, and the argument for each is the comment above it. A
# value in .env would be a number with nowhere to write down why.
MIN_SEED_SECONDS = 72 * 3600      # the floor: 72h before anything may stop
MAX_RATIO = 1.5                   # then stop at ratio 1.5 ...
MAX_SEED_MINUTES = 7 * 24 * 60    # ... or a week of seeding, whichever is first

# qBittorrent's two sentinels, which do NOT mean the same thing and are the
# easiest part of this API to get backwards:
#   -2  use the global limit
#   -1  no limit at all
UNLIMITED = -1
USE_GLOBAL = -2

# (ratio, seeding minutes, inactive minutes) for each of the two states a
# torrent can be in here. Inactive seeding time is left unlimited in both: it
# stops a torrent for being unpopular, which is the opposite of the obligation
# this policy exists to honour.
HOLDING = (float(UNLIMITED), UNLIMITED, UNLIMITED)
MANAGED = (float(MAX_RATIO), MAX_SEED_MINUTES, UNLIMITED)

# What the global preferences must be for the floor to hold. max_ratio_act stays
# 0 (stop the torrent) because stopping is what Radarr and Sonarr wait for; the
# two _enabled flags are the ones that would let a torrent be reaped before this
# script has promoted it.
GLOBAL_POLICY = {
    "max_ratio_enabled": False,
    "max_seeding_time_enabled": False,
    "max_inactive_seeding_time_enabled": False,
    "max_ratio_act": 0,
}


class QbtError(RuntimeError):
    """The client could not be reached or refused. Never a policy decision."""


def load_env():
    """The .env, read directly so this works from an interactive shell too."""
    env = {}
    try:
        with open(ENV_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    env[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return env


def qbt(port, path, data=None, timeout=30):
    """A call to the WebUI from inside the pod, with no credential needed.

    The request is configured through `curl -K -` rather than argv. There is no
    secret here to keep out of the process list, but the same shape is what
    lets the data line below stay unquoted, and it costs nothing.

    THE `data =` LINE IS DELIBERATELY UNQUOTED. curl takes the rest of the line
    literally when a config value does not open with a quote, which means the
    JSON payload's own double quotes need no backslash escaping - and an
    escaping bug here would look exactly like the API rejecting the request.
    """
    config = ['url = "http://localhost:%s/api/v2/%s"' % (port, path),
              "silent", "show-error", "fail", "max-time = 20"]
    if data is not None:
        config.append("data = %s" % data)
    try:
        res = subprocess.run(
            ["podman", "exec", "-i", CONTAINER, "curl", "-K", "-"],
            input="\n".join(config) + "\n", capture_output=True,
            text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise QbtError("could not exec into %s: %s" % (CONTAINER, exc))
    if res.returncode != 0:
        raise QbtError("%s failed (exit %d) %s"
                       % (path, res.returncode, (res.stderr or "").strip()))
    return res.stdout


def qbt_json(port, path):
    body = qbt(port, path)
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        raise QbtError("%s did not return JSON" % path)


def enforce_global(port, dry_run, verbose):
    """Assert the global limits are off, and correct them if they are not.

    Re-asserted every run rather than set once, because this is the invariant
    the whole floor rests on and it lives in a UI anybody can click.
    """
    prefs = qbt_json(port, "app/preferences")
    drift = {k: v for k, v in GLOBAL_POLICY.items() if prefs.get(k) != v}
    if not drift:
        if verbose:
            print("global: share limits already off, action=stop")
        return []
    changed = ["%s=%s -> %s" % (k, prefs.get(k), v) for k, v in sorted(drift.items())]
    if dry_run:
        print("global: WOULD correct %s" % ", ".join(changed))
        return changed
    payload = json.dumps(drift, separators=(",", ":"))
    qbt(port, "app/setPreferences", data="json=" + payload)
    print("global: corrected %s" % ", ".join(changed))
    return changed


def current_limits(tor):
    return (float(tor.get("ratio_limit", USE_GLOBAL)),
            int(tor.get("seeding_time_limit", USE_GLOBAL)),
            int(tor.get("inactive_seeding_time_limit", USE_GLOBAL)))


def apply_limits(port, hashes, limits, dry_run):
    """setShareLimits takes a pipe-separated hash list, so this is one call."""
    ratio, seed_minutes, inactive = limits
    data = ("hashes=%s&ratioLimit=%s&seedingTimeLimit=%d"
            "&inactiveSeedingTimeLimit=%d"
            % ("|".join(hashes), ratio, seed_minutes, inactive))
    if dry_run:
        return
    qbt(port, "torrents/setShareLimits", data=data)


def write_marker(started, ok, counts):
    """The durable record of a successful run.

    A unit exiting 0 is not one: ExecMainExitTimestamp is runtime state that a
    reboot wipes, so "never ran" and "has not run since we booted" look alike.
    A failing run carries the previous last_ok_at forward so that "failing since
    Tuesday" and "has never once worked" stay distinguishable.
    """
    previous = {}
    try:
        with open(MARKER, encoding="ascii") as fh:
            for line in fh:
                if "=" in line:
                    key, _, value = line.strip().partition("=")
                    previous[key] = value
    except OSError:
        pass
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))
    state = {
        "last_run_at": stamp,
        "last_ok_at": stamp if ok else previous.get("last_ok_at", ""),
        "managed": str(counts.get("managed", 0)),
        "holding": str(counts.get("holding", 0)),
        "changed": str(counts.get("changed", 0)),
        "min_seed_hours": str(MIN_SEED_SECONDS // 3600),
        "max_ratio": str(MAX_RATIO),
        "max_seed_days": str(MAX_SEED_MINUTES // (24 * 60)),
    }
    body = "".join("%s=%s\n" % kv for kv in sorted(state.items()))
    try:
        os.makedirs(os.path.dirname(MARKER), exist_ok=True)
        tmp = MARKER + ".tmp"
        with open(tmp, "w", encoding="ascii") as fh:
            fh.write(body)
        os.replace(tmp, MARKER)
    except OSError as exc:
        print("apply-seeding-policy: could not write %s: %s" % (MARKER, exc),
              file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Hold torrents for 72h, then let them stop at ratio 1.5 "
                    "or one week.")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would change, touch nothing")
    parser.add_argument("--verbose", action="store_true",
                        help="one line per torrent")
    args = parser.parse_args()

    started = time.time()
    port = load_env().get("PORT_QBITTORRENT_WEB", "8200")
    counts = {"managed": 0, "holding": 0, "changed": 0}

    try:
        enforce_global(port, args.dry_run, args.verbose)
        torrents = qbt_json(port, "torrents/info")
        if not isinstance(torrents, list):
            raise QbtError("torrents/info did not return a list")

        # Batched by destination state, so this is at most two API calls
        # whatever the library size.
        pending = {HOLDING: [], MANAGED: []}
        for tor in torrents:
            seeded = int(tor.get("seeding_time", 0))
            past_floor = seeded >= MIN_SEED_SECONDS
            want = MANAGED if past_floor else HOLDING
            counts["managed" if past_floor else "holding"] += 1
            if current_limits(tor) != want:
                pending[want].append(tor["hash"])
                counts["changed"] += 1
                if args.verbose:
                    print("%-8s %5.1fd ratio=%.2f  %s"
                          % ("promote" if past_floor else "hold",
                             seeded / 86400.0, tor.get("ratio", 0.0),
                             tor.get("name", "")[:56]))

        for want, hashes in pending.items():
            if hashes:
                apply_limits(port, hashes, want, args.dry_run)
    except QbtError as exc:
        print("apply-seeding-policy: %s" % exc, file=sys.stderr)
        write_marker(started, False, counts)
        return 1

    verb = "would change" if args.dry_run else "changed"
    print("seeding policy: %d past the %dh floor, %d holding, %s %d"
          % (counts["managed"], MIN_SEED_SECONDS // 3600, counts["holding"],
             verb, counts["changed"]))
    if not args.dry_run:
        write_marker(started, True, counts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
