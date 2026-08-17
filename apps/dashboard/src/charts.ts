// =============================================================================
// SVG path arithmetic
// -----------------------------------------------------------------------------
// There is no chart library here, deliberately. The design is hand-drawn SVG
// throughout - a polyline, an area beneath it, a dashed median, a row of bars -
// and matching it exactly costs less than bending a charting library into it,
// at zero dependency weight and no runtime that has to be kept current.
//
// THE ONE THING WORTH GETTING RIGHT IS THE GAP. A Prometheus range query
// returns nothing at all for a timestamp where the series did not exist, and
// `polyline` cannot express a break - it would draw a straight line across the
// outage, which reads as "steady" when it means "absent". So lines are built as
// a `path` with a fresh M after every gap.
// =============================================================================

/** [unix seconds, value]. A NaN value is an explicit hole. */
export type Point = [number, number];

export interface Extent {
  min: number;
  max: number;
}

/**
 * The vertical extent to draw at. `floorAtZero` is the usual case - a CPU or
 * byte count starting anywhere but zero exaggerates every wobble into a cliff.
 * `pad` lifts the top so the maximum is not welded to the frame.
 */
export function extent(points: Point[], options: { floorAtZero?: boolean; pad?: number } = {}): Extent {
  const values = points.map(([, v]) => v).filter((v) => Number.isFinite(v));
  if (values.length === 0) return { min: 0, max: 1 };

  let min = options.floorAtZero === false ? Math.min(...values) : 0;
  let max = Math.max(...values);

  if (max === min) {
    // A perfectly flat series still needs a box to be drawn in, and it should
    // sit in the middle of it rather than along an edge.
    max = min === 0 ? 1 : min * 1.5;
  }

  const pad = options.pad ?? 0.08;
  max += (max - min) * pad;
  return { min, max };
}

export interface Frame {
  width: number;
  height: number;
  extent: Extent;
  /** Time range. Defaults to the first and last point. */
  from?: number;
  to?: number;
}

/**
 * One line on a chart. A chart drawing more than one of these is drawing things
 * that must share a y-scale to be comparable - the two GPUs being the case that
 * called for it - so the extent is always computed across all of them.
 */
export interface ChartSeries {
  points: Point[];
  /** Names the series in a readout. The GPU lanes use the card index. */
  label?: string;
  tone?: "ok" | "warn" | "fail";
}

/** Where a time falls horizontally. The only thing a crosshair needs. */
export function projectX(t: number, frame: Frame, points: Point[] = []): number {
  const from = frame.from ?? points[0]?.[0] ?? 0;
  const to = frame.to ?? points[points.length - 1]?.[0] ?? from + 1;
  return ((t - from) / (to - from || 1)) * frame.width;
}

/** Where a value falls vertically, clamped into the frame. */
export function projectY(v: number, frame: Frame): number {
  const range = frame.extent.max - frame.extent.min || 1;
  const clamped = Number.isFinite(v) ? Math.min(frame.extent.max, Math.max(frame.extent.min, v)) : frame.extent.min;
  return frame.height - ((clamped - frame.extent.min) / range) * frame.height;
}

function project(points: Point[], frame: Frame): (readonly [number, number, boolean])[] {
  return points.map((p) => {
    const [, v] = p;
    return [projectX(p[0], frame, points), projectY(v, frame), Number.isFinite(v)] as const;
  });
}

function round(n: number): string {
  return (Math.round(n * 100) / 100).toString();
}

/** The line, with a break wherever the series has no value. */
export function linePath(points: Point[], frame: Frame): string {
  const projected = project(points, frame);
  let out = "";
  let open = false;

  for (const [x, y, finite] of projected) {
    if (!finite) {
      open = false;
      continue;
    }
    out += `${open ? "L" : "M"}${round(x)} ${round(y)}`;
    open = true;
  }
  return out;
}

/**
 * The fill beneath the line. Built per contiguous run for the same reason:
 * one polygon spanning a gap would shade an interval that has no data.
 */
export function areaPath(points: Point[], frame: Frame): string {
  const projected = project(points, frame);
  const runs: (readonly [number, number, boolean])[][] = [];
  let run: (readonly [number, number, boolean])[] = [];

  for (const p of projected) {
    if (p[2]) {
      run.push(p);
    } else if (run.length) {
      runs.push(run);
      run = [];
    }
  }
  if (run.length) runs.push(run);

  return runs
    .filter((r) => r.length > 1)
    .map((r) => {
      const head = r[0];
      const tail = r[r.length - 1];
      const line = r.map(([x, y]) => `L${round(x)} ${round(y)}`).join("");
      return `M${round(head[0])} ${round(frame.height)}${line}L${round(tail[0])} ${round(frame.height)}Z`;
    })
    .join("");
}

/** A flat dashed reference line, which the design uses for the median. */
export function medianPath(points: Point[], frame: Frame): string {
  const values = points.map(([, v]) => v).filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
  if (values.length === 0) return "";

  const mid = values.length % 2 ? values[(values.length - 1) / 2] : (values[values.length / 2 - 1] + values[values.length / 2]) / 2;
  const range = frame.extent.max - frame.extent.min || 1;
  const y = frame.height - ((mid - frame.extent.min) / range) * frame.height;
  return `M0 ${round(y)}L${round(frame.width)} ${round(y)}`;
}

export function median(points: Point[]): number {
  const values = points.map(([, v]) => v).filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
  if (values.length === 0) return Number.NaN;
  return values.length % 2
    ? values[(values.length - 1) / 2]
    : (values[values.length / 2 - 1] + values[values.length / 2]) / 2;
}

/**
 * The sample nearest `t`. A hole is returned as the NaN it is rather than
 * skipped to the nearest real value: the cursor sitting in a gap must read as
 * "no data here", not as the last number before it.
 */
export function sampleAt(points: Point[], t: number): Point | null {
  let best: Point | null = null;
  let bestGap = Infinity;

  for (const p of points) {
    const gap = Math.abs(p[0] - t);
    if (gap < bestGap) {
      bestGap = gap;
      best = p;
    }
  }
  return best;
}

export function peak(points: Point[]): number {
  const values = points.map(([, v]) => v).filter(Number.isFinite);
  return values.length ? Math.max(...values) : Number.NaN;
}

export function latest(points: Point[]): number {
  for (let i = points.length - 1; i >= 0; i -= 1) {
    if (Number.isFinite(points[i][1])) return points[i][1];
  }
  return Number.NaN;
}

/** Prometheus range samples to points, preserving holes as NaN. */
export function toPoints(values: [number, string][]): Point[] {
  return values.map(([t, v]) => [t, Number(v)] as Point);
}

/**
 * Resample onto a fixed grid so a series with holes still has a point at every
 * step - which is what makes a gap visible rather than merely absent.
 */
export function onGrid(points: Point[], from: number, to: number, step: number): Point[] {
  const byBucket = new Map<number, number>();
  for (const [t, v] of points) byBucket.set(Math.round(t / step) * step, v);

  const out: Point[] = [];
  for (let t = Math.ceil(from / step) * step; t <= to; t += step) {
    out.push([t, byBucket.get(t) ?? Number.NaN]);
  }
  return out;
}
