// =============================================================================
// Prometheus, through Caddy, on the same origin
// -----------------------------------------------------------------------------
// The browser never talks to prometheus:9090 - it cannot, that name only
// resolves on net-metrics. Caddy proxies /api/prom/* under the dashboard's own
// hostname, which buys three things at once: one origin so there is no CORS,
// one sign-on boundary so there is no second credential, and the SAME
// /api/v1/admin/* refusal that metrics.<domain> already carries.
//
// Everything here is a read. There is no write path to add.
// =============================================================================

import { fetchJson } from "./http";
import type { InstantSeries, PromResponse, RangeSeries, Sample } from "@/types";

const BASE = "/api/prom/api/v1";

function unwrap<T>(body: PromResponse<T>): T {
  if (body.status !== "success") {
    throw new Error(body.error ?? "prometheus returned an error with no reason");
  }
  return body.data.result;
}

/** The value of a sample as a number. NaN stays NaN rather than becoming 0 -
 *  "no data" and "zero" are different answers and must render differently. */
export function value(sample: Sample | undefined): number {
  return sample ? Number(sample[1]) : Number.NaN;
}

export async function instant(query: string, signal?: AbortSignal): Promise<InstantSeries[]> {
  const params = new URLSearchParams({ query });
  const body = await fetchJson<PromResponse<InstantSeries[]>>(`${BASE}/query?${params}`, { signal });
  return unwrap(body);
}

/** A single number, or NaN when the query matched nothing. */
export async function scalar(query: string, signal?: AbortSignal): Promise<number> {
  const result = await instant(query, signal);
  return value(result[0]?.value);
}

export interface RangeOptions {
  /** Seconds of history. */
  window: number;
  /** Seconds between points. Prometheus caps a range query at 11,000 points. */
  step: number;
  end?: number;
  signal?: AbortSignal;
}

export async function range(query: string, options: RangeOptions): Promise<RangeSeries[]> {
  const end = options.end ?? Math.floor(Date.now() / 1000);
  const start = end - options.window;

  // Align to the step so that consecutive polls ask for the same buckets and
  // Prometheus can answer from its query cache, instead of shifting the whole
  // series by a second or two and making every chart jitter.
  const step = Math.max(1, Math.round(options.step));
  const params = new URLSearchParams({
    query,
    start: String(Math.floor(start / step) * step),
    end: String(Math.floor(end / step) * step),
    step: String(step),
  });

  const body = await fetchJson<PromResponse<RangeSeries[]>>(`${BASE}/query_range?${params}`, {
    signal: options.signal,
  });
  return unwrap(body);
}

/**
 * Instant query reduced to a plain map keyed by one label. Most of this
 * dashboard is "one number per container" or "one number per device", and the
 * alternative is the same three lines of find() at every call site.
 */
export async function instantBy(
  query: string,
  label: string,
  signal?: AbortSignal,
): Promise<Map<string, number>> {
  const result = await instant(query, signal);
  const out = new Map<string, number>();
  for (const series of result) {
    const key = series.metric[label];
    if (key !== undefined) out.set(key, value(series.value));
  }
  return out;
}

/**
 * Instant query reduced to the full label set, keyed by one label. For the
 * `*_info` metrics, which carry their payload in labels and always have the
 * value 1 - home_server_container_info{container,unit,image,pod} being the one
 * that makes the whole Services page possible without a lookup table.
 */
export async function labelsBy(
  query: string,
  label: string,
  signal?: AbortSignal,
): Promise<Map<string, Record<string, string>>> {
  const result = await instant(query, signal);
  const out = new Map<string, Record<string, string>>();
  for (const series of result) {
    const key = series.metric[label];
    if (key !== undefined) out.set(key, series.metric);
  }
  return out;
}
