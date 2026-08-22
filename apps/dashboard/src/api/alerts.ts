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

/**
 * The dead man's switch. `expr: vector(1)` in apps/prometheus/rules, so it is
 * ALWAYS firing, and firing is the HEALTHY state: its arrival on the phone each
 * day is the only proof the four-hop notification chain works, and its absence
 * is the finding.
 *
 * Which makes it the one alert that must not be drawn like an alert. It was a
 * permanent amber row in the panel and a permanent amber tick on the timeline,
 * rendered identically to a real warning, because this module fetched with no
 * filter and the page coloured anything that was not `critical` as warn.
 */
export const HEARTBEAT_SEVERITY = "heartbeat";

export function isHeartbeat(a: AmAlert): boolean {
  return a.labels.severity === HEARTBEAT_SEVERITY;
}

/** Sort worst-first, then most recent first. Critical before warning, because
 *  the whole point of a grouped view is that the top line is the one to read.
 *  The heartbeat ranks last EXPLICITLY rather than by falling off the end of
 *  the ternary - it is not a milder problem, it is not a problem. */
export function bySeverityThenTime(a: AmAlert, b: AmAlert): number {
  const rank = (x: AmAlert) =>
    x.labels.severity === "critical" ? 0 : x.labels.severity === "warning" ? 1 : isHeartbeat(x) ? 3 : 2;
  const d = rank(a) - rank(b);
  if (d !== 0) return d;
  return Date.parse(b.startsAt) - Date.parse(a.startsAt);
}
