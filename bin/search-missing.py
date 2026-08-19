#!/usr/bin/env python3
# ==============================================================================
# Search again for what is missing, because nothing else ever will
# ------------------------------------------------------------------------------
# RUNS ON THE SERVER, from a systemd user timer. See host/systemd/.
#
# THE GAP THIS CLOSES. Sonarr and Radarr search for a title exactly once, when
# it is added. After that the only automatic discovery is RSS sync, which reads
# what each indexer has published RECENTLY - so it can never find a film from
# 2012 or a series that ended in 2004. If that one add-time search lands while
# indexers are backing off, or while a stalled queue item is blocking the
# release, the title stays missing for ever and every signal stays green.
#
# Measured on 2026-08-19, which is why this file exists: Sex and the City was
# added the previous evening, 0 of 94 episodes present, and an interactive
# search returned three approved 1080p releases with 5-21 seeders. The releases
# were there the whole time. Nothing had asked for them a second time.
#
# IT ASKS THE APPLICATIONS TO SEARCH AND NOTHING ELSE. Scoring, approval,
# grabbing and importing all stay where they are. This script's entire blast
# radius is "a search command was queued", which is the same restraint
# bin/promote-transcoded.py keeps when it declines to move a media file.
#
# FOUR REFUSALS, and each of them is load-bearing rather than tidy:
#
#   1. NEVER SEARCH SOMETHING THAT IS NOT OUT YET. Sixteen of the twenty-one
#      films Radarr wanted on 2026-08-19 were `status=announced` - Avengers:
#      Doomsday, The Legend of Zelda, Narnia 2027. No indexer on earth has them,
#      and searching them daily would be the bulk of this job's load for ever.
#
#      DO NOT USE Radarr's own `isAvailable` FOR THIS. Every movie here carries
#      `minimumAvailability: announced`, so `isAvailable` is true for all
#      twenty-one, a 2027 release included. It answers "may Radarr grab this",
#      not "does this exist", and the two are the same field only by accident.
#
#   2. NEVER SEARCH SOMETHING ALREADY IN THE QUEUE. Radarr rejects every
#      candidate for a movie whose queued download already meets cutoff - all
#      49 of Kaamelott's, with the reason "Quality for release in queue already
#      meets cutoff". A search there is pure indexer load with a guaranteed
#      empty result.
#
#   3. NEVER RE-SEARCH THE SAME THING EVERY TICK. A title that genuinely does
#      not exist must not become a permanent load generator, so each item
#      carries its own last-searched stamp and is left alone for a week.
#
#   4. NEVER FIRE MORE THAN A HANDFUL PER RUN. A newly added 94-episode series
#      would otherwise put ninety-four searches across every indexer into one
#      burst. Prowlarr was already returning `429 TooManyRequests` to Sonarr
#      before this script existed; a reconciler that makes discovery WORSE
#      would be indistinguishable from one that helps. So a series drains over
#      several nights instead, which is the correct trade for something nobody
#      is waiting on minute by minute.
#
# IT SEARCHES BY EPISODE, AND THE FIRST VERSION SEARCHED BY SEASON. That was
# the obvious economy - one query instead of thirteen - and the first live run
# disproved it. All six seasons of Sex and the City came back
# `Season search completed. 0 reports downloaded`, processing 4 to 10 releases
# each, because a season query asks for a season PACK and these trackers index
# this show one episode at a time. The identical set of episodes searched
# individually queued all twelve of season one within the hour. A cheaper query
# that returns nothing is not cheaper.
#
# IT NAMES A STALL, IT DOES NOT CLEAR ONE. A download stuck at "no connections"
# blocks every alternative release for that item, so it is the single most
# effective way to be unable to find something that is plentifully available -
# and it is invisible, because the queue reports the item as `downloading`.
# This script prints it and counts it. Removing it deletes a partial download
# and is a decision for a person, not for a timer.
#
# WHY IT RUNS ON THE HOST rather than in a container: `podman exec` reaches
# Sonarr and Radarr regardless of network topology, so nothing on any segment
# gains reachability it did not have. Same argument as
# bin/promote-transcoded.py and bin/apply-seeding-policy.py.
#
# Usage:  bin/search-missing.py [--dry-run] [--verbose] [--limit N]
# ==============================================================================

import argparse
import calendar
import json
import os
import subprocess
import sys
import time

# Derived from this file's own location rather than hardcoded, so moving the
# checkout does not silently point this at an .env that is not there.
REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
ENV_FILE = os.path.join(REPO, ".env")
MARKER = os.path.expanduser("~/.cache/home-server/search-state")

# The ports are the ones the applications listen on INSIDE their own container,
# which is what `podman exec` lands next to. They are not the published ports,
# because nothing here is published - the same constants bin/collect-metrics.py
# uses for the same reason.
RADARR = ("radarr", 7878)
SONARR = ("sonarr", 8989)

# HOW OFTEN THE SAME ITEM MAY BE ASKED FOR AGAIN. Seven days against a daily
# timer, so a title nobody has released yet costs one search a week rather than
# one a day. The number is a decision about how this house treats other
# people's trackers, not a deployment parameter - which is why it is a constant
# with an argument next to it rather than a variable in .env.
RESEARCH_SECONDS = 7 * 24 * 3600

# The per-run ceiling, counted across both applications in ITEMS - one film or
# one episode, because each is its own query against every indexer.
#
# MEASURED RATHER THAN GUESSED, on 2026-08-19: twelve episodes against eight
# active indexers is 96 queries, took about seven minutes, and produced zero
# 429s and zero indexers backing off. Twenty-four a day is 192 queries, which is
# a fraction of what RSS sync already does unattended - eight indexers every
# fifteen minutes is nearer 770 - so this is a small addition to a load the
# stack already carries, not a new one.
DEFAULT_LIMIT = 24

# How long a queue item may sit before it is called stalled rather than slow.
# A 30 GB remux legitimately takes many hours; five days at "no connections"
# does not, and that is what was actually found.
STALL_HOURS = 24


class ArrError(RuntimeError):
    """The application could not be reached or refused. Never a verdict."""


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


def api(app, key, path, payload=None, timeout=90):
    """A call to an *arr API from inside its own container.

    THE CREDENTIAL GOES IN ON STDIN, NOT ARGV. `curl -K -` reads its whole
    configuration from stdin, so the API key never reaches the host's process
    list - which `podman exec ... -H "X-Api-Key: ..."` cannot avoid.

    THE `data =` LINE IS DELIBERATELY UNQUOTED, for the reason
    bin/apply-seeding-policy.py records: curl takes the rest of the line
    literally when the value does not open with a quote, so the JSON payload's
    own double quotes need no escaping. An escaping bug here would look exactly
    like the API rejecting the request.
    """
    container, port = app
    config = ['url = "http://localhost:%d/api/v3/%s"' % (port, path),
              'header = "X-Api-Key: %s"' % key,
              "silent", "show-error", "fail", "max-time = 60"]
    if payload is not None:
        config.append('header = "Content-Type: application/json"')
        config.append('request = "POST"')
        config.append("data = %s" % json.dumps(payload, separators=(",", ":")))
    try:
        res = subprocess.run(
            ["podman", "exec", "-i", container, "curl", "-K", "-"],
            input="\n".join(config) + "\n", capture_output=True,
            text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ArrError("could not exec into %s: %s" % (container, exc))
    if res.returncode != 0:
        raise ArrError("%s %s failed (exit %d) %s"
                       % (container, path, res.returncode,
                          (res.stderr or "").strip()))
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        raise ArrError("%s %s did not return JSON" % (container, path))


def epoch(stamp):
    """An ISO-8601 timestamp from an *arr API, as epoch seconds, or None.

    They come back as `2026-08-19T10:24:01Z` and occasionally with fractional
    seconds. Both are truncated to the same 19 characters rather than parsed
    with a format string per variant.

    calendar.timegm, NOT time.mktime. mktime reads the struct as LOCAL time and
    applies a DST correction of its own, so the obvious `mktime(...) - timezone`
    is out by an hour for half the year - which is invisible against a 7-day
    interval and wrong against an air date.
    """
    if not stamp or not isinstance(stamp, str) or len(stamp) < 19:
        return None
    try:
        return calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, OverflowError):
        return None


def is_released(movie, now):
    """Does this film exist to be found, as opposed to merely being wanted?

    `status` is the honest field. `isAvailable` is not: with
    minimumAvailability=announced - which every movie here carries - it reads
    true for a film that is two years from a cinema.
    """
    if movie.get("status") == "released":
        return True
    for field in ("digitalRelease", "physicalRelease"):
        when = epoch(movie.get(field))
        if when is not None and when <= now:
            return True
    return False


def stalled_items(queue, now):
    """Queue entries that have stopped moving, as (label, reason) pairs.

    A stall is reported and never cleared. It matters because it is silent AND
    blocking: the item reads `downloading`, and every alternative release for it
    is refused as "already meets cutoff", so the symptom is "this cannot be
    found" arriving from the one place that already has it.
    """
    found = []
    for row in queue:
        added = epoch(row.get("added"))
        if added is None or now - added < STALL_HOURS * 3600:
            continue
        messages = [row.get("errorMessage") or ""]
        for block in row.get("statusMessages") or []:
            messages.extend(block.get("messages") or [])
        reason = next((m for m in messages if m), "")
        warned = row.get("trackedDownloadStatus") in ("warning", "error")
        if not warned and "stall" not in reason.lower():
            continue
        title = (row.get("movie") or {}).get("title") \
            or (row.get("series") or {}).get("title") \
            or row.get("title") or "?"
        found.append(("%s (%.0fh)" % (title, (now - added) / 3600.0),
                      reason or row.get("trackedDownloadStatus", "")))
    return found


def radarr_plan(key, state, now, verbose):
    """Which films to search, and the three counts that explain the rest."""
    movies = api(RADARR, key, "movie")
    queue = api(RADARR, key, "queue?pageSize=200&includeMovie=true")
    if not isinstance(movies, list) or not isinstance(queue, dict):
        raise ArrError("radarr did not return the expected shapes")
    in_flight = {row.get("movieId") for row in queue.get("records") or []}

    missing = [m for m in movies
               if not m.get("hasFile") and m.get("monitored")]
    searchable = [m for m in missing if is_released(m, now)]
    due = []
    for movie in searchable:
        if movie["id"] in in_flight:
            if verbose:
                print("skip  in queue     %s" % movie.get("title", "")[:56])
            continue
        last = int(state.get("item_movie_%d" % movie["id"], 0) or 0)
        if now - last < RESEARCH_SECONDS:
            if verbose:
                print("skip  searched %2dd  %s"
                      % ((now - last) / 86400, movie.get("title", "")[:56]))
            continue
        due.append(movie)
    return {
        "missing": len(missing),
        "searchable": len(searchable),
        "due": due,
        "queue": queue.get("records") or [],
    }


def sonarr_plan(key, state, now, verbose):
    """Which episodes to search, grouped by season only to batch the call.

    BY EPISODE, NOT BY SEASON, and that is the opposite of what this function
    did first. A season query asks an indexer for a season PACK; these trackers
    index an older series one episode at a time, so all six seasons of Sex and
    the City returned `0 reports downloaded` while the same episodes searched
    individually queued twelve of twelve. The grouping survives only as a way to
    send one command per season instead of one per episode - Sonarr issues the
    indexer queries either way, so the grouping saves API calls and nothing else.
    """
    wanted = api(SONARR, key,
                 "wanted/missing?page=1&pageSize=1000&includeSeries=true"
                 "&sortKey=airDateUtc&sortDirection=ascending")
    queue = api(SONARR, key, "queue?pageSize=200")
    if not isinstance(wanted, dict) or not isinstance(queue, dict):
        raise ArrError("sonarr did not return the expected shapes")
    in_flight = {row.get("episodeId") for row in queue.get("records") or []}

    records = wanted.get("records") or []
    missing = [e for e in records if e.get("monitored")]
    # An episode with no air date has not aired: Sonarr leaves airDateUtc unset
    # for an announced episode, and treating unset as "long ago" would search
    # for next season every day.
    aired = []
    for ep in missing:
        when = epoch(ep.get("airDateUtc"))
        if when is not None and when <= now:
            aired.append(ep)

    due = []
    for ep in aired:
        title = (ep.get("series") or {}).get("title", "?")
        label = "%s S%02dE%02d" % (title[:44], ep.get("seasonNumber", 0),
                                  ep.get("episodeNumber", 0))
        if ep["id"] in in_flight:
            if verbose:
                print("skip  in queue     %s" % label)
            continue
        last = int(state.get("item_episode_%d" % ep["id"], 0) or 0)
        if now - last < RESEARCH_SECONDS:
            if verbose:
                print("skip  searched %2dd  %s" % ((now - last) / 86400, label))
            continue
        due.append({"id": ep["id"], "seriesId": ep["seriesId"],
                    "season": ep.get("seasonNumber", 0), "label": label})
    return {
        "missing": len(missing),
        "searchable": len(aired),
        "due": due,
        "queue": queue.get("records") or [],
    }


def write_marker(started, ok, facts):
    """The durable record of a successful run.

    A unit exiting 0 is not one: ExecMainExitTimestamp is runtime state that a
    reboot wipes, so "never ran" and "has not run since we booted" look alike.
    A failing run carries the previous last_ok_at forward, so "failing since
    Tuesday" and "has never once worked" stay distinguishable.

    The per-item stamps live in this same file under `item_` keys. One file, one
    atomic write, and bin/verify-host.sh keeps reading the flat `key=value`
    shape it already reads for the seeding policy.
    """
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))
    state = dict(facts)
    state["last_run_at"] = stamp
    state["last_ok_at"] = stamp if ok else facts.get("last_ok_at", "")
    body = "".join("%s=%s\n" % (k, v) for k, v in sorted(state.items()))
    try:
        os.makedirs(os.path.dirname(MARKER), exist_ok=True)
        tmp = MARKER + ".tmp"
        with open(tmp, "w", encoding="ascii") as fh:
            fh.write(body)
        os.replace(tmp, MARKER)
    except OSError as exc:
        print("search-missing: could not write %s: %s" % (MARKER, exc),
              file=sys.stderr)


def read_state():
    state = {}
    try:
        with open(MARKER, encoding="ascii") as fh:
            for line in fh:
                if "=" in line:
                    key, _, value = line.strip().partition("=")
                    state[key] = value
    except OSError:
        pass
    return state


def main():
    parser = argparse.ArgumentParser(
        description="Ask Sonarr and Radarr to search again for what is "
                    "missing, released, and not already in the queue.")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would be searched, ask for nothing")
    parser.add_argument("--verbose", action="store_true",
                        help="one line per item, skipped ones included")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT,
                        help="ceiling on searches per run (default %d)"
                             % DEFAULT_LIMIT)
    args = parser.parse_args()

    started = time.time()
    now = int(started)
    env = load_env()
    state = read_state()
    facts = {"last_ok_at": state.get("last_ok_at", "")}
    # Every previous item stamp is carried forward; only the ones searched this
    # run are rewritten. Dropping them would re-search everything every tick.
    #
    # A stamp older than twice the re-search interval is dropped instead, which
    # is what stops this file growing for ever as items are grabbed, deleted or
    # renamed. It cannot cause an early re-search: anything that old is already
    # past due, so the two branches agree.
    for key, value in state.items():
        if not key.startswith(("item_movie_", "item_episode_")):
            continue
        try:
            if now - int(value) < 2 * RESEARCH_SECONDS:
                facts[key] = value
        except (TypeError, ValueError):
            continue

    radarr_key = env.get("RADARR_API_KEY", "")
    sonarr_key = env.get("SONARR_API_KEY", "")
    if not radarr_key or not sonarr_key:
        print("search-missing: RADARR_API_KEY or SONARR_API_KEY is not set in "
              "%s" % ENV_FILE, file=sys.stderr)
        return 1

    try:
        radarr = radarr_plan(radarr_key, state, now, args.verbose)
        sonarr = sonarr_plan(sonarr_key, state, now, args.verbose)

        # THE CAP IS SHARED AND COUNTED IN ITEMS - one film or one episode -
        # because each is its own query against every indexer, which is the only
        # cost that matters here. Films are taken first because there are few of
        # them and a whole series would otherwise starve them for days; anything
        # not reached this run is still due tomorrow.
        budget = max(0, args.limit)
        movies = radarr["due"][:budget]
        budget -= len(movies)
        episodes = sonarr["due"][:budget]

        for movie in movies:
            print("%-7s movie    %s (%s)"
                  % ("WOULD" if args.dry_run else "search",
                     movie.get("title", "?"), movie.get("year", "?")))
        for ep in episodes:
            print("%-7s episode  %s"
                  % ("WOULD" if args.dry_run else "search", ep["label"]))

        stalls = (stalled_items(radarr["queue"], now)
                  + stalled_items(sonarr["queue"], now))
        for label, reason in stalls:
            # NAMED, NEVER CLEARED. It blocks every alternative release for that
            # item, so it is worth shouting about - and removing it deletes a
            # partial download, which is a person's decision.
            print("STALLED %s: %s" % (label, reason))

        if not args.dry_run:
            if movies:
                api(RADARR, radarr_key, "command",
                    {"name": "MoviesSearch",
                     "movieIds": [m["id"] for m in movies]})
                for movie in movies:
                    facts["item_movie_%d" % movie["id"]] = now
            # One command per season rather than per episode. Sonarr issues the
            # same indexer queries either way; this only keeps the API chatter
            # proportional to seasons instead of to episodes.
            batches = {}
            for ep in episodes:
                batches.setdefault((ep["seriesId"], ep["season"]), []).append(ep)
            for (_series_id, _season), group in sorted(batches.items()):
                api(SONARR, sonarr_key, "command",
                    {"name": "EpisodeSearch",
                     "episodeIds": [ep["id"] for ep in group]})
                for ep in group:
                    facts["item_episode_%d" % ep["id"]] = now
    except ArrError as exc:
        print("search-missing: %s" % exc, file=sys.stderr)
        write_marker(started, False, facts)
        return 1

    facts.update({
        "movies_missing": radarr["missing"],
        "movies_searchable": radarr["searchable"],
        "movies_due": len(radarr["due"]),
        "episodes_missing": sonarr["missing"],
        "episodes_searchable": sonarr["searchable"],
        "episodes_due": len(sonarr["due"]),
        "searched": len(movies) + len(episodes),
        "stalled": len(stalls),
    })

    # THE TWO NUMBERS ARE REPORTED SEPARATELY ON PURPOSE, for the reason
    # home_server_subtitles_missing and _wanted_items already record: 21 films
    # missing of which 16 are not released yet is a HEALTHY number, and a single
    # total would have read as 21 things going wrong.
    print("search sweep: %d/%d films and %d/%d episodes are actually out; "
          "%s %d, %d stalled"
          % (radarr["searchable"], radarr["missing"],
             sonarr["searchable"], sonarr["missing"],
             "would search" if args.dry_run else "searched",
             len(movies) + len(episodes), len(stalls)))
    if not args.dry_run:
        write_marker(started, True, facts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
