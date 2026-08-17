// =============================================================================
// activity.json and library.json - what a series is not allowed to carry
// -----------------------------------------------------------------------------
// bin/collect-metrics.py writes both into ${DOCKER_VOLUME_CACHE}/dashboard/,
// beside status.json, and this container has that directory bind-mounted
// read-only at /srv/data. Its own Caddyfile already serves /data/* with
// `Cache-Control: no-store`, so neither file needed a routing change.
//
// They exist because titles cannot be Prometheus labels. Cardinality is the
// obvious reason and the lesser one - the collector deliberately refuses to
// label a session with the user, the device or the item, because a 400-day
// series of who watched what is surveillance of the household rather than
// monitoring of a machine. A document is rewritten whole every run and keeps no
// history, which is what makes carrying a title in one acceptable.
//
// TWO FILES BECAUSE THEY HAVE TWO CADENCES, not because they have two readers.
// activity.json is rewritten every 30 seconds and library.json every 5 minutes,
// for the reason the collector's own textfile split records: a five-minute slice
// living in a thirty-second file blinks out nine ticks in ten and renders as a
// sawtooth that looks exactly like a fault. Both pages read both.
// =============================================================================

import { fetchJson, HttpError } from "./http";
import type { ActivityDocument, LibraryDocument } from "@/types";

const ACTIVITY_PATH = "/data/activity.json";
const LIBRARY_PATH = "/data/library.json";

/**
 * Distinguishable from a fetch failure: the collector has not written this here.
 * On a fresh host that means the timer has not run yet, which is a different
 * thing from broken - the same distinction StatusNeverWritten draws.
 */
export class DocumentNeverWritten extends Error {
  readonly doc: string;

  constructor(doc: string) {
    super(`${doc} has not been written yet`);
    this.name = "DocumentNeverWritten";
    this.doc = doc;
  }
}

async function fetchDocument<T>(path: string, name: string, signal?: AbortSignal): Promise<T> {
  try {
    // Cache-busted on top of the server's no-store for the reason status.ts
    // gives: a 304 from an intermediate would let a frozen playback position
    // read as current, and a progress bar is the one thing here that looks
    // plausible while being wrong.
    return await fetchJson<T>(`${path}?t=${Date.now()}`, { signal });
  } catch (error) {
    if (error instanceof HttpError && error.status === 404) throw new DocumentNeverWritten(name);
    throw error;
  }
}

export function fetchActivity(signal?: AbortSignal): Promise<ActivityDocument> {
  return fetchDocument<ActivityDocument>(ACTIVITY_PATH, "activity.json", signal);
}

export function fetchLibrary(signal?: AbortSignal): Promise<LibraryDocument> {
  return fetchDocument<LibraryDocument>(LIBRARY_PATH, "library.json", signal);
}
