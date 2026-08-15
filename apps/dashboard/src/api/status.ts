// =============================================================================
// status.json - the prose half of every finding
// -----------------------------------------------------------------------------
// bin/verify-host.sh writes /var/lib/home-server/status.json hourly, and a
// second copy into ${DOCKER_VOLUME_CACHE}/dashboard/ which this container has
// bind-mounted read-only at /srv/data. The canonical file is root-owned inside
// a var_lib_t directory, which no rootless container may read and which `:z`
// cannot fix - relabelling is done by the invoking user, and `core` does not
// own that directory.
//
// Prometheus already carries every VERDICT as home_server_check_status{id,
// section}. What it deliberately does not carry is the MESSAGE. That split is
// the intended join, and it is why both sources are read: the id is stable and
// alertable, the prose is readable and disposable.
// =============================================================================

import { fetchJson, HttpError } from "./http";
import type { StatusDocument } from "@/types";

const URL_PATH = "/data/status.json";

/** Distinguishable from a fetch failure: the battery has never run here. */
export class StatusNeverWritten extends Error {
  constructor() {
    super("status.json has not been written yet");
    this.name = "StatusNeverWritten";
  }
}

export async function fetchStatus(signal?: AbortSignal): Promise<StatusDocument> {
  try {
    // Cache-busted on top of the server's no-store, because a 304 from an
    // intermediate would make a stale battery read as a current one - which
    // is the exact failure this dashboard exists to make visible.
    const doc = await fetchJson<StatusDocument>(`${URL_PATH}?t=${Date.now()}`, { signal });
    return doc;
  } catch (error) {
    // 404 means the file is not there, which on a fresh host means the timer
    // has not fired yet rather than that anything is broken. Say so.
    if (error instanceof HttpError && error.status === 404) throw new StatusNeverWritten();
    throw error;
  }
}
