// =============================================================================
// Alertmanager, read-only
// -----------------------------------------------------------------------------
// This panel is where the design's "Log stream" was, and the swap is
// deliberate. CLAUDE.md is explicit that a log tail must not be built here:
// Jellyfin alone emits 2,644 priority-3 lines a day of ffmpeg decoder chatter
// with no lever to turn it off, so a live tail is noise with a cursor on it.
//
// Alertmanager is the opposite. It groups, it suppresses repeats, and it tells
// you when a thing STOPS being true - the three behaviours CLAUDE.md names as
// deciding whether a channel is still being read in six months. It also had no
// interface at all until now: it gets no public route, and ntfy-alertmanager's
// silence button was declined precisely because it would have needed one.
//
// Caddy proxies only its read paths; anything that is not GET or HEAD is
// refused 405 at the edge, because POST /api/v2/silences is how an alert gets
// muted and that is not a decision to make from a dashboard.
// =============================================================================

import { fetchJson } from "./http";
import type { AmAlert } from "@/types";

const BASE = "/api/alerts/api/v2";

export async function fetchAlerts(signal?: AbortSignal): Promise<AmAlert[]> {
  const params = new URLSearchParams({
    active: "true",
    silenced: "true",
    inhibited: "true",
    unprocessed: "true",
  });
  return await fetchJson<AmAlert[]>(`${BASE}/alerts?${params}`, { signal });
}

/** Sort worst-first, then most recent first. Critical before warning, because
 *  the whole point of a grouped view is that the top line is the one to read. */
export function bySeverityThenTime(a: AmAlert, b: AmAlert): number {
  const rank = (x: AmAlert) => (x.labels.severity === "critical" ? 0 : x.labels.severity === "warning" ? 1 : 2);
  const d = rank(a) - rank(b);
  if (d !== 0) return d;
  return Date.parse(b.startsAt) - Date.parse(a.startsAt);
}
