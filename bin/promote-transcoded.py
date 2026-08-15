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

ENV_FILE = "/var/home-server/.env"

# The one tree, seen three ways: the host mounts it at /mnt/media, the *arr apps
# see it at /data, and Tdarr at /media. Only the prefix differs.
HOST_LIBRARY = "/mnt/media/library"
ARR_LIBRARY = "/data/library"

# What counts as "the film is here". Checking for the DIRECTORY does not work
# and silently disabled this whole script: Tdarr deletes the video file with
# deleteParentFolderIfEmpty, but the folder still holds fanart.jpg, poster.jpg
# and a .nfo, so it is never empty and never removed. Every film therefore
# looked like it was still in queued/ and nothing was ever reconciled - which
# is the same symptom this script was written to fix.
VIDEO_EXTENSIONS = (".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".m2ts",
                    ".wmv", ".flv", ".webm", ".mpg", ".mpeg", ".vob", ".evo")


def has_video(directory):
    """True if the directory holds at least one video file, at any depth."""
    try:
        for _root, _dirs, files in os.walk(directory):
            for name in files:
                if name.lower().endswith(VIDEO_EXTENSIONS):
                    return True
    except OSError:
        pass
    return False


# Tdarr's verdicts that mean "this file is finished". If one of these is recorded
# against a path that is STILL in queued/ with its video intact, the flow decided
# it was done and then failed to move it - which is invisible from the filesystem
# alone, because that looks identical to a file still waiting its turn.
#
# That is not hypothetical. runClassicTranscodePlugin 2.0.0 leaves an
# already-compliant file on outputNumber 2, and avsOnePass1 had no edge wired to
# it, so the flow ended before its move-to-directory node. The Hobbit: The Battle
# of the Five Armies sat in queued/ for a day while Radarr, Tdarr and Jellyfin
# were each individually correct and this script printed "1 waiting on Tdarr"
# every ten minutes. See apps/tdarr/flows/README.md.
TDARR_DONE_VERDICTS = ("Not required", "Transcode success")

# Tdarr sees the same tree at a third prefix - /media, where the host says
# /mnt/media and the *arr apps say /data. Its file table is keyed by that path.
TDARR_LIBRARY = "/media/library"


# One *arr app can own SEVERAL library types, and each is a separate root folder
# pair. Radarr holds films under queued/movies and documentaries under
# queued/documentaries; Sonarr holds series and anime the same way.
#
# This used to be a single `kind` per service, which meant a transcoded
# documentary moved to transcoded/documentaries and Radarr was never told - the
# identical failure to the one described above, just in a folder nobody was
# watching. The reconciliation has to be per KIND, not per service, because the
# editor call sets one rootFolderPath for the whole batch.
SERVICES = {
    "radarr": {
        "container": "radarr", "port": 7878, "key": "RADARR_API_KEY",
        "list": "movie", "editor": "movie/editor", "ids": "movieIds",
        "rescan": "RescanMovie", "kinds": ("movies", "documentaries"),
    },
    "sonarr": {
        "container": "sonarr", "port": 8989, "key": "SONARR_API_KEY",
        "list": "series", "editor": "series/editor", "ids": "seriesIds",
        "rescan": "RescanSeries", "kinds": ("series", "anime"),
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


def tdarr_finished_paths():
    """Paths Tdarr considers done, as a set of its own /media/... keys.

    Returns an empty set if Tdarr cannot be reached or answers something
    unexpected, which degrades to the old behaviour rather than inventing a
    stall. This is a diagnostic, and it must never be able to break or delay the
    reconciliation it annotates - the same reasoning as the leading `-` on
    jellyfin.container's ExecStartPre.
    """
    body = json.dumps({"data": {"collection": "FileJSONDB", "mode": "getAll"}})
    out = exec_curl("tdarr-server",
                    ["-X", "POST", "-H", "Content-Type: application/json",
                     "http://localhost:8266/api/v2/cruddb"], body)
    if out is None:
        return set()
    try:
        rows = json.loads(out)
    except json.JSONDecodeError:
        return set()
    if not isinstance(rows, list):
        return set()
    return set(r.get("_id", "") for r in rows
               if isinstance(r, dict)
               and r.get("TranscodeDecisionMaker") in TDARR_DONE_VERDICTS)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="change nothing")
    ap.add_argument("--once", action="store_true", help="single pass (the default)")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    keys = load_env(ENV_FILE)
    promoted_any = False

    # Asked once per run, not per kind: it is the same table for all four.
    finished = tdarr_finished_paths()

    for svc, cfg in SERVICES.items():
        items = arr(svc, "GET", cfg["list"], keys=keys)
        if items is None:
            print("== %s: API did not answer, skipping" % svc)
            continue

        # The editor call sets rootFolderPath, and an *arr app rejects a path
        # that is not one of its configured root folders. Without this check the
        # failure is a silent no-op on exactly the type nobody is watching, so
        # ask once and refuse loudly per kind.
        roots = arr(svc, "GET", "rootfolder", keys=keys) or []
        known = set(r.get("path", "").rstrip("/") for r in roots)

        rescan_needed = False
        for kind in cfg["kinds"]:
            queued_arr = "%s/queued/%s" % (ARR_LIBRARY, kind)
            target_arr = "%s/transcoded/%s" % (ARR_LIBRARY, kind)

            promote, waiting, undownloaded, stuck = [], 0, 0, []
            for it in items:
                path = it.get("path") or ""
                if not path.startswith(queued_arr + "/"):
                    continue  # already promoted, or a different kind entirely
                leaf = path[len(queued_arr) + 1:]
                gone = not has_video("%s/queued/%s/%s" % (HOST_LIBRARY, kind, leaf))
                arrived = has_video("%s/transcoded/%s/%s" % (HOST_LIBRARY, kind, leaf))
                if gone and arrived:
                    promote.append(it)
                    continue
                if gone:
                    # No video in EITHER place, so there is nothing for Tdarr to
                    # be working on: this is a monitored title that has not been
                    # downloaded yet. Counting it as "waiting on Tdarr" made the
                    # number meaningless - 50 wishlist entries were added in one
                    # day and turned "1 waiting" into "51 waiting" overnight,
                    # which is exactly the kind of noise that gets a line ignored.
                    undownloaded += 1
                    continue
                waiting += 1
                # Still in queued/, and Tdarr has already recorded a verdict that
                # means it is finished with the file. No number of further passes
                # will move it: the flow ended before its move node. Without this,
                # "waiting on Tdarr" covers both a live transcode and a permanent
                # stall, and the two are indistinguishable from out here.
                prefix = "%s/queued/%s/%s/" % (TDARR_LIBRARY, kind, leaf)
                if any(p.startswith(prefix) for p in finished):
                    stuck.append(it)

            if args.verbose:
                print("== %s/%s: %d still in queued/, %d moved by Tdarr, "
                      "%d not downloaded yet"
                      % (svc, kind, waiting, len(promote), undownloaded))
            for it in stuck:
                print("== %s/%s: STUCK: %s" % (svc, kind, it.get("title") or it.get("path")),
                      file=sys.stderr)
                print("   Tdarr has finished with it but it is still in queued/ - the flow "
                      "ended before its move node. See apps/tdarr/flows/README.md.",
                      file=sys.stderr)
            if not promote:
                if waiting or args.verbose:
                    print("== %s/%s: nothing to reconcile (%d waiting on Tdarr)"
                          % (svc, kind, waiting))
                continue

            if target_arr.rstrip("/") not in known:
                print("== %s/%s: %d ready, but %s is not a root folder in %s - "
                      "add it or they stay invisible"
                      % (svc, kind, len(promote), target_arr, svc), file=sys.stderr)
                continue

            print("== %s/%s: reconciling %d that Tdarr has already moved"
                  % (svc, kind, len(promote)))
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
            rescan_needed = True
            promoted_any = True

        # One rescan per application, after all its kinds - it is a full-library
        # command, so calling it per kind would just repeat the same work.
        if rescan_needed and not args.dry_run:
            arr(svc, "POST", "command", {"name": cfg["rescan"]}, keys)

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
