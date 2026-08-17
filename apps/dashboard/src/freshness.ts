// =============================================================================
// How old is this, and does that make it untrustworthy
// -----------------------------------------------------------------------------
// Lifted out of src/stores/host.ts unchanged, because there are now five
// independent freshness primitives rather than three - status.json, the
// collector, `up`, and the two dashboard documents - and each fails in a way the
// others cannot see. Five private copies of the same arithmetic is how they
// start disagreeing.
//
// THE RULE THE WHOLE REPOSITORY IS WRITTEN AROUND: a stale dashboard must read
// as stale, never as healthy. "The battery says everything passed" and "nobody
// has asked the battery" must not look alike, which is why `missing` is a
// separate field from `stale` rather than an old age.
// =============================================================================

export interface Freshness {
  label: string;
  /** Seconds since the thing last succeeded. NaN when never, or unknown. */
  age: number;
  threshold: number;
  stale: boolean;
  /** True when the source has never reported at all, which is not the same
   *  as being old - a fresh host and a broken one must not look alike. */
  missing: boolean;
}

export function freshness(label: string, at: number, now: number, threshold: number): Freshness {
  if (!Number.isFinite(at) || at <= 0) {
    return { label, age: Number.NaN, threshold, stale: true, missing: true };
  }
  const age = now - at;
  return { label, age, threshold, stale: age > threshold, missing: false };
}
