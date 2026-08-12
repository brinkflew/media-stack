#!/usr/bin/env python3
# ==============================================================================
# Tell Radarr and Sonarr that Tdarr moved their files
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, from a systemd user timer. See host/systemd/.
#
# WHAT ACTUALLY HAPPENS, which took a while to establish. Tdarr's flow already
# promotes files itself: the "5 - Save File" stage ends in
#
#     File Save - Move To Directory Done
#       outputDirectory: {{args.userVariables.library.output_dir_done}}
#       keepRelativePath: true
#
# and every library sets output_dir_done to /media/library/transcoded/<type>.
# So the queued -> transcoded promotion is NOT missing. What is missing is
# anybody telling the *arr apps, which still believe the file is in queued/.
#
# That is exactly how Flow and The Hobbit ended up sitting in transcoded/movies
# while Radarr reported hasFile=false and stood ready to download them again.
#
# THIS SCRIPT THEREFORE NEVER MOVES A FILE. An earlier version called the editor
# endpoints with moveFiles=true, which was wrong twice over: the file has
# already gone from queued/ by the time this runs, and a second mover competing
# with the flow is precisely the class of bug being fixed. It updates the root
# folder with moveFiles=false and asks for a rescan, so the application
# re-discovers the file where Tdarr actually put it.
#
# It reads the filesystem directly rather than asking Tdarr, because the truth
# it needs is "where is the file now", not "what did Tdarr decide". That works
# whatever moved it, and needs no Tdarr API and no coupling to its schema.
#
# WHY THIS RUNS ON THE HOST. net-transcode is Options=isolate=true, so Tdarr
# cannot reach Radarr, Sonarr or Jellyfin, deliberately. `podman exec` works
# regardless of network topology, so this grants nothing to any container.
#
# Usage:  bin/promote-transcoded.py [--dry-run] [--once] [--verbose]
# ==============================================================================

import argparse
import json
import os
import subprocess
import sys

ENV_FILE = "/var/media-stack/.env"

# The one tree, seen three ways: the host mounts it at /mnt/media, the *arr apps
# see it at /data, and Tdarr at /media. Only the prefix differs.
HOST_LIBRARY = "/mnt/media/library"
ARR_LIBRARY = "/data/library"

SERVICES = {
    "radarr": {
        "container": "radarr", "port": 7878, "key": "RADARR_API_KEY",
        "list": "movie", "editor": "movie/editor", "ids": "movieIds",
        "rescan": "RescanMovie", "kind": "movies",
    },
    "sonarr": {
        "container": "sonarr", "port": 8989, "key": "SONARR_API_KEY",
        "list": "series", "editor": "series/editor", "ids": "seriesIds",
        "rescan": "RescanSeries", "kind": "series",
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
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc))
    return env


def exec_curl(container, args, body=None):
    """curl inside a container. The body goes over stdin so an API key never
    appears in the process list."""
    cmd = ["podman", "exec"]
    if body is not None:
        cmd.append("-i")
        args = args + ["--data-binary", "@-"]
    cmd += [container, "curl", "-s", "--max-time", "60"] + args
    proc = subprocess.run(cmd, input=body, capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def arr(svc, method, path, payload=None, keys=None):
    cfg = SERVICES[svc]
    key = keys.get(cfg["key"], "")
    if not key:
        die("%s is not set in %s" % (cfg["key"], ENV_FILE))
    url = "http://localhost:%d/api/v3/%s" % (cfg["port"], path)
    args = ["-X", method, "-H", "X-Api-Key: %s" % key,
            "-H", "Content-Type: application/json", url]
    out = exec_curl(cfg["container"], args, json.dumps(payload) if payload else None)
    if out is None:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="change nothing")
    ap.add_argument("--once", action="store_true", help="single pass (the default)")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    keys = load_env(ENV_FILE)
    promoted_any = False

    for svc, cfg in SERVICES.items():
        kind = cfg["kind"]
        queued_arr = "%s/queued/%s" % (ARR_LIBRARY, kind)
        target_arr = "%s/transcoded/%s" % (ARR_LIBRARY, kind)

        items = arr(svc, "GET", cfg["list"], keys=keys)
        if items is None:
            print("== %s: API did not answer, skipping" % svc)
            continue

        promote, waiting = [], 0
        for it in items:
            path = it.get("path") or ""
            if not path.startswith(queued_arr + "/"):
                continue  # already promoted, or somewhere else entirely
            leaf = path[len(queued_arr) + 1:]
            gone = not os.path.isdir("%s/queued/%s/%s" % (HOST_LIBRARY, kind, leaf))
            arrived = os.path.isdir("%s/transcoded/%s/%s" % (HOST_LIBRARY, kind, leaf))
            if gone and arrived:
                promote.append(it)
            else:
                waiting += 1

        if args.verbose:
            print("== %s: %d still in queued/, %d moved by Tdarr" % (svc, waiting, len(promote)))
        if not promote:
            print("== %s: nothing to reconcile (%d waiting on Tdarr)" % (svc, waiting))
            continue

        print("== %s: reconciling %d that Tdarr has already moved" % (svc, len(promote)))
        for it in promote:
            print("   ->     %s" % (it.get("title") or it.get("path")))
        if args.dry_run:
            continue

        # moveFiles=false: the file is ALREADY at the target. Asking the
        # application to move it would fail on a source that no longer exists.
        payload = {cfg["ids"]: [it["id"] for it in promote],
                   "rootFolderPath": target_arr, "moveFiles": False}
        if arr(svc, "PUT", cfg["editor"], payload, keys) is None:
            print("   %s editor call failed - nothing changed" % svc, file=sys.stderr)
            continue
        # Then make it look at disk again, so the file is re-detected in place.
        arr(svc, "POST", "command",
            {"name": cfg["rescan"]}, keys)
        promoted_any = True

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
