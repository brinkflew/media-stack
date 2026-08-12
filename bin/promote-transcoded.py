#!/usr/bin/env python3
# ==============================================================================
# Promote transcoded, health-checked media from library/queued into
# library/transcoded, so Jellyfin only ever sees finished files
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, from a systemd user timer. See host/systemd/.
#
# THE PROBLEM THIS EXISTS TO SOLVE. The library is a pipeline:
#
#     *arr import -> library/queued/<type> -> Tdarr -> library/transcoded/<type>
#                                                      ^ the only thing Jellyfin reads
#
# Tdarr transcodes in place and leaves the file in queued/, so without this
# nothing ever reaches transcoded/ and a perfectly good film is invisible in
# Jellyfin for ever. That was the actual state of the stack: Radarr said the file
# was there, Jellyfin had never heard of it, and neither was wrong.
#
# WHY THIS RUNS ON THE HOST RATHER THAN IN A CONTAINER. net-transcode carries
# Options=isolate=true and holds only Caddy and the three Tdarr containers, so
# tdarr-server cannot reach Radarr, Sonarr or Jellyfin - deliberately, because
# FlareSolverr-adjacent things should not be able to reach the *arr apps. Putting
# a notifier inside Tdarr would mean flattening that. The host has no such
# restriction: `podman exec` reaches into any container whatever the network
# topology says, so this grants nothing new to anybody.
#
# WHY THE *ARR APPS DO THEIR OWN MOVING. This script never touches a media file.
# It calls Radarr's and Sonarr's editor endpoints with moveFiles=true, so the
# application relocates the file AND updates its own database in one operation.
# Anything that moves a file behind an *arr's back orphans it - which is exactly
# what happened to Flow and The Hobbit, both sitting in transcoded/ while Radarr
# reported hasFile=false and stood ready to download them again.
#
# Usage:  bin/promote-transcoded.py [--dry-run] [--once] [--verbose]
#           --dry-run   report what would be promoted, change nothing
#           --once      single pass; this is the default, the flag is for clarity
# ==============================================================================

import argparse
import json
import subprocess
import sys

ENV_FILE = "/var/media-stack/.env"

# Tdarr sees the media root at /media, the *arr apps see it at /data. Only the
# prefix differs, so every path is compared as its remainder after the mount.
TDARR_PREFIX = "/media/"
ARR_PREFIX = "/data/"

# A file is promoted only when Tdarr has both transcoded it and verified it.
# Kept as a set because Tdarr's vocabulary has grown before; anything outside
# this set and outside PENDING is reported rather than silently treated as ready.
BLESSED = {"Success"}
PENDING = {"Queued", "Not required", "Ignored", "Skipped"}

SERVICES = {
    "radarr": {
        "container": "radarr", "port": 7878, "api": "v3", "key": "RADARR_API_KEY",
        "list": "movie", "editor": "movie/editor", "ids": "movieIds",
        "queued": "/data/library/queued/movies",
        "target": "/data/library/transcoded/movies",
    },
    "sonarr": {
        "container": "sonarr", "port": 8989, "api": "v3", "key": "SONARR_API_KEY",
        "list": "series", "editor": "series/editor", "ids": "seriesIds",
        "queued": "/data/library/queued/series",
        "target": "/data/library/transcoded/series",
    },
}


def die(msg):
    print("promote-transcoded: %s" % msg, file=sys.stderr)
    sys.exit(1)


def load_env(path):
    env = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc))
    return env


def exec_curl(container, args, body=None):
    """Run curl inside a container. stdin carries the body so it never appears in
    the process list, where an API key would otherwise be world-readable."""
    cmd = ["podman", "exec"]
    if body is not None:
        cmd.append("-i")
        args = args + ["--data-binary", "@-"]
    cmd += [container, "curl", "-s", "--max-time", "60"] + args
    proc = subprocess.run(cmd, input=body, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return proc.stdout


def arr(svc, method, path, payload=None, keys=None):
    cfg = SERVICES[svc]
    key = keys.get(cfg["key"], "")
    if not key:
        die("%s is not set in %s" % (cfg["key"], ENV_FILE))
    url = "http://localhost:%d/api/%s/%s" % (cfg["port"], cfg["api"], path)
    args = ["-X", method, "-H", "X-Api-Key: %s" % key,
            "-H", "Content-Type: application/json", url]
    out = exec_curl(cfg["container"], args, json.dumps(payload) if payload else None)
    if out is None:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def tdarr_files():
    """Every file Tdarr knows about, with its transcode and health verdicts.
    Tdarr's API needs no key from inside its own container."""
    body = json.dumps({"data": {"collection": "FileJSONDB", "mode": "getAll"}})
    out = exec_curl("tdarr-server",
                    ["-X", "POST", "-H", "Content-Type: application/json",
                     "http://localhost:8266/api/v2/cruddb"], body)
    if out is None:
        die("cannot reach tdarr-server - is the container running?")
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        die("tdarr-server returned something that is not JSON")
    if not isinstance(data, list):
        die("tdarr-server returned %s, expected a list of files" % type(data).__name__)
    return data


def rel(path, prefix):
    return path[len(prefix):] if path.startswith(prefix) else None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="change nothing")
    ap.add_argument("--once", action="store_true", help="single pass (the default)")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    keys = load_env(ENV_FILE)
    files = tdarr_files()

    # Bucket every Tdarr-known file under library/queued by its verdict.
    ready, waiting, stuck = {}, {}, []
    for f in files:
        rp = rel(f.get("file", ""), TDARR_PREFIX)
        if rp is None or not rp.startswith("library/queued/"):
            continue
        td, hc = f.get("TranscodeDecisionMaker"), f.get("HealthCheck")
        if td in BLESSED and hc in BLESSED:
            ready[rp] = f
        elif td in PENDING or hc in PENDING:
            waiting[rp] = f
        else:
            stuck.append((rp, td, hc))

    print("== tdarr: %d ready, %d still working, %d stuck" %
          (len(ready), len(waiting), len(stuck)))
    for rp, td, hc in stuck:
        # Loud, because a file that fails here is invisible in Jellyfin for ever
        # and the gate working correctly is indistinguishable from nothing
        # happening. This is the only warning anyone gets.
        print("   STUCK  %-58s transcode=%s health=%s" % (rp[-58:], td, hc))

    promoted_any = False
    for svc, cfg in SERVICES.items():
        items = arr(svc, "GET", cfg["list"], keys=keys)
        if items is None:
            print("== %s: API did not answer, skipping" % svc)
            continue

        qrel = rel(cfg["queued"], ARR_PREFIX)
        promote, held = [], []
        for it in items:
            ipath = it.get("path") or ""
            irel = rel(ipath, ARR_PREFIX)
            if irel is None or not irel.startswith(qrel):
                continue  # already promoted, or living somewhere else entirely

            # Every Tdarr-known file under this item must be blessed. For a movie
            # that is one file; for a series it is the whole tree, and promoting
            # a series whose episodes are half-transcoded would move the rest out
            # from under Tdarr mid-job.
            mine_ready = [p for p in ready if p.startswith(irel + "/")]
            mine_waiting = [p for p in waiting if p.startswith(irel + "/")]
            mine_stuck = [p for p, _, _ in stuck if p.startswith(irel + "/")]

            if mine_ready and not mine_waiting and not mine_stuck:
                promote.append(it)
            elif mine_waiting or mine_stuck:
                held.append((it, len(mine_ready), len(mine_waiting), len(mine_stuck)))

        if args.verbose or held:
            for it, r, w, s in held:
                print("   hold   %-46s ready=%d waiting=%d stuck=%d"
                      % ((it.get("title") or "?")[:46], r, w, s))

        if not promote:
            print("== %s: nothing ready to promote" % svc)
            continue

        print("== %s: promoting %d" % (svc, len(promote)))
        for it in promote:
            print("   ->     %s" % (it.get("title") or it.get("path")))
        if args.dry_run:
            continue

        payload = {cfg["ids"]: [it["id"] for it in promote],
                   "rootFolderPath": cfg["target"], "moveFiles": True}
        if arr(svc, "PUT", cfg["editor"], payload, keys) is None:
            print("   %s editor call failed - nothing moved" % svc, file=sys.stderr)
        else:
            promoted_any = True

    # Jellyfin picks new files up on its own schedule; nudging it is the
    # difference between "available now" and "available within the hour".
    if promoted_any and not args.dry_run:
        jkey = keys.get("JELLYFIN_API_KEY", "")
        if not jkey:
            print("== jellyfin: JELLYFIN_API_KEY not set, leaving the scan to its schedule")
        else:
            exec_curl("jellyfin", ["-X", "POST", "-H", "X-Emby-Token: %s" % jkey,
                                   "http://localhost:8096/Library/Refresh"])
            print("== jellyfin: library scan requested")


if __name__ == "__main__":
    main()
