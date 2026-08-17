// =============================================================================
// Turning a range query into thirty daily availability ratios
// -----------------------------------------------------------------------------
// Prometheus can do this in PromQL - avg_over_time(...[1d]) at a 1d step - but
// that lands the buckets on UTC midnight of the query, not on local days, and
// it silently returns fewer points than asked for when the store does not go
// back far enough. Both matter here: the second is exactly the case that must
// render grey rather than green.
// =============================================================================

import type { Point } from "@/charts";

export const DAY_S = 86400;

/**
 * Bucket samples into local days and average each one. Days with no sample at
 * all come back NaN, which UptimeBars draws grey - "no evidence" rather than
 * "perfect".
 */
export function dailyRatios(points: Point[], days: number, now = Date.now() / 1000): number[] {
  const sums = new Array<number>(days).fill(0);
  const counts = new Array<number>(days).fill(0);

  // Local midnight of today, so the rightmost bar is the day in progress.
  const midnight = new Date(now * 1000);
  midnight.setHours(0, 0, 0, 0);
  const todayStart = midnight.getTime() / 1000;

  for (const [t, v] of points) {
    if (!Number.isFinite(v)) continue;

    // CLAMPED AT ZERO, AND THAT IS THE WHOLE BUG THIS ONCE HAD. Samples taken
    // since local midnight are "today", but they are AFTER todayStart, so the
    // raw offset is -1 and the index lands one past the last bar - silently
    // discarding every one of them. Anything genuinely older still fails the
    // guard below.
    const offset = Math.max(0, Math.floor((todayStart - t) / DAY_S + 1e-9));
    const index = days - 1 - offset;
    if (index < 0 || index >= days) continue;
    sums[index] += v;
    counts[index] += 1;
  }

  return sums.map((sum, i) => (counts[i] === 0 ? Number.NaN : sum / counts[i]));
}

/**
 * The date each bar stands for, oldest first - the same indexing dailyRatios
 * writes, so the two cannot drift. Local midnights, because that is what the
 * buckets are.
 */
export function dayStarts(days: number, now = Date.now() / 1000): number[] {
  const midnight = new Date(now * 1000);
  midnight.setHours(0, 0, 0, 0);
  const todayStart = midnight.getTime() / 1000;

  return Array.from({ length: days }, (_, i) => todayStart - (days - 1 - i) * DAY_S);
}

/** The headline for a bar row: mean of the days that have data, and how many
 *  that was when it is not all of them. */
export function ratioSummary(days: number[]): string {
  const known = days.filter(Number.isFinite);
  if (known.length === 0) return "no data";

  const mean = known.reduce((a, b) => a + b, 0) / known.length;
  const text = `${(mean * 100).toFixed(mean > 0.999 ? 2 : 1)}%`;
  return known.length === days.length ? text : `${text} over ${known.length}d`;
}
