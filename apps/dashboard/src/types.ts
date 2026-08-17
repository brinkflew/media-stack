// =============================================================================
// The two wire formats this dashboard reads
// -----------------------------------------------------------------------------
// Both are somebody else's contract, so these types are a transcription rather
// than a design. bin/verify-host.sh owns the first; Prometheus owns the second.
//
// THE ONE RULE THAT MATTERS, from CLAUDE.md: "Every finding is keyed by a
// STABLE ID, and the prose is not stable." Key on `id`. Never parse `message`,
// never switch on it, never assume its wording - it gets reworded whenever it
// turns out to be wrong, and that must cost nothing.
// =============================================================================

/**
 * The only four colours anything here may be, from the design brief: "Status has
 * three colors only: teal healthy, amber degraded, red failing. Everything else
 * is grey." `off` IS that grey and it is not a fourth status - it means nobody
 * measured, which must never be rendered as healthy.
 *
 * Declared here rather than per-page because five modules now need it.
 * StatusDot and MetricChart keep their own inline prop unions: those are
 * component contracts, and churning them buys nothing.
 */
export type Tone = "ok" | "warn" | "fail" | "off";

/** Ordered worst-last, so `Math.max` over the numeric rank is the verdict. */
export type CheckStatus = "pass" | "note" | "warn" | "fail";

/** Matches home_server_check_status: 0 pass, 1 note, 2 warn, 3 fail. */
export const STATUS_RANK: Record<CheckStatus, number> = {
  pass: 0,
  note: 1,
  warn: 2,
  fail: 3,
};

export const RANK_STATUS: CheckStatus[] = ["pass", "note", "warn", "fail"];

export interface Check {
  /** Section id, e.g. "backup". Matches Section.id. */
  section: string;
  /** Dotted and stable, e.g. "cdi.driver_match". The only thing to key on. */
  id: string;
  status: CheckStatus;
  /** Human prose. Display it; never depend on it. */
  message: string;
}

export interface Section {
  id: string;
  title: string;
  pass: number;
  fail: number;
  warn: number;
  note: number;
}

export interface StatusSummary {
  /** Precomputed with fail > warn > pass precedence. Colour on this. */
  status: "pass" | "warn" | "fail";
  pass: number;
  fail: number;
  warn: number;
  note: number;
  total: number;
}

/**
 * Flat snake_case, always present, `null` when not measured - so a key never
 * appears and disappears. Values are string, number, boolean or null; the
 * `*_at` ones are ISO 8601 UTC.
 */
export type Facts = Record<string, string | number | boolean | null>;

export interface StatusDocument {
  schema: number;
  /** ISO 8601 UTC. Authoritative: this is how old the whole document is. */
  generated_at: string;
  host: string;
  /**
   * Which optional batteries ran. `routes: false` means the route battery was
   * NOT walked - which must never be rendered as "every route passed".
   */
  mode: { routes: boolean };
  summary: StatusSummary;
  /** A section that did not run is ABSENT here, not zero-filled. */
  sections: Section[];
  checks: Check[];
  facts: Facts;
}

// -----------------------------------------------------------------------------
// Prometheus HTTP API
// -----------------------------------------------------------------------------

/** [unix seconds, value as a string]. The string is not a mistake - it is how
 *  Prometheus preserves NaN, +Inf and full float64 precision over JSON. */
export type Sample = [number, string];

export interface InstantSeries {
  metric: Record<string, string>;
  value: Sample;
}

export interface RangeSeries {
  metric: Record<string, string>;
  values: Sample[];
}

export interface PromResponse<T> {
  status: "success" | "error";
  data: { resultType: string; result: T };
  errorType?: string;
  error?: string;
}

// -----------------------------------------------------------------------------
// Alertmanager v2
// -----------------------------------------------------------------------------

export interface AmAlert {
  labels: Record<string, string>;
  annotations: Record<string, string>;
  startsAt: string;
  endsAt: string;
  updatedAt: string;
  status: { state: "active" | "suppressed" | "unprocessed"; silencedBy: string[]; inhibitedBy: string[] };
  generatorURL?: string;
  fingerprint?: string;
}
