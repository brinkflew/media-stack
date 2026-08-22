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
//
// ONE GEOMETRIC FACT GOVERNS EVERYTHING THAT TOUCHES PIXELS. MetricChart draws
// into a fixed viewBox of `0 0 900 height` with preserveAspectRatio="none", and
// the element is `height` CSS pixels tall. So the vertical scale is exactly 1
// and the horizontal one is whatever the column happens to be wide:
//
//     A VERTICAL FRAME UNIT IS A CSS PIXEL. A HORIZONTAL ONE IS NOTHING.
//
// That asymmetry is what makes `yTicks` cheap - an HTML label at `top: <y>px`
// lands exactly on the rule drawn at `y=<y>` with no measurement and no second
// source of truth - and it is why an x position has to be a percentage of the
// element's own width instead.
// =============================================================================

/** [unix seconds, value]. A NaN value is an explicit hole. */
export type Point = [number, number];

export interface Extent {
  min: number;
  max: number;
}

export interface ExtentOptions {
  floorAtZero?: boolean;
  pad?: number;
  /**
   * A hard ceiling: CPU pinned to 1, memory pinned to MemTotal. NEVER PADDED,
   * and given no flat-series rescue - both of those exist to invent a frame for
   * data that does not imply one, and a pinned ceiling IS the frame. A 100%
   * chart whose frame tops out at 108% is not a 100% chart.
   *
   * A non-finite value here reads as ABSENT rather than as a ceiling of zero:
   * MemTotal arrives from its own query and is NaN on the first paint.
   */
  max?: number;
  /** A hard floor. Overrides floorAtZero. */
  min?: number;
}

/**
 * The vertical extent to draw at. `floorAtZero` is the usual case - a CPU or
 * byte count starting anywhere but zero exaggerates every wobble into a cliff.
 * `pad` lifts the top so the maximum is not welded to the frame.
 */
export function extent(points: Point[], options: ExtentOptions = {}): Extent {
  const fixedMax = Number.isFinite(options.max as number);
  const fixedMin = Number.isFinite(options.min as number);

  const values = points.map(([, v]) => v).filter((v) => Number.isFinite(v));
  if (values.length === 0 && !fixedMax) return { min: fixedMin ? (options.min as number) : 0, max: 1 };

  const min = fixedMin
    ? (options.min as number)
    : options.floorAtZero === false
      ? Math.min(...values)
      : 0;

  if (fixedMax) {
    const max = options.max as number;
    return { min, max: max > min ? max : min + 1 };
  }

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
  /**
   * Which half of a mirrored chart this series is drawn in. THE VALUES STAY
   * POSITIVE EITHER WAY, and only `projectYSigned` reads this.
   *
   * Negating them in the data layer would be simpler to draw and silently wrong
   * everywhere else: `peak()` on a negated series returns Math.max of negatives,
   * which is the SMALLEST rate out - a 40 MB/s upload peak reported as the
   * quietest moment in the window, with nothing thrown - and fmt.bytes already
   * carries a sign, so it would render "-40.0 MB/s" quite happily. median() and
   * sampleAt() are shared with four readouts on the System page; six call sites
   * would each need a Math.abs, and every one missed is a wrong number that
   * renders.
   */
  direction?: "up" | "down";
  /**
   * Overrides the brightness ramp. Set where the series are INTERCHANGEABLE and
   * a ramp would invent a ranking among them: the twelve CPU cores are twelve
   * of the same thing, and drawing core 11 at a third of core 0 says something
   * about core 11 that is not true.
   */
  opacity?: number;
  /** Stroke width. The aggregate drawn over a fleet of thin lines is the one
   *  use, and it is why `opacity` alone is not enough. */
  width?: number;
}

/** Where a time falls horizontally. The only thing a crosshair needs. */
export function projectX(t: number, frame: Frame, points: Point[] = []): number {
  const from = frame.from ?? points[0]?.[0] ?? 0;
  const to = frame.to ?? points[points.length - 1]?.[0] ?? from + 1;
  return ((t - from) / (to - from || 1)) * frame.width;
}

/**
 * Where a value falls vertically, clamped into the frame.
 *
 * A HOLE PROJECTS TO NaN, NOT TO THE FLOOR. It used to answer `extent.min`,
 * which was harmless while every extent started at zero and lethal the moment
 * one did not: under the symmetric extent of a mirrored chart, extent.min is
 * the BOTTOM of the frame, so an unguarded caller drew every gap as a
 * full-scale spike downward. Every caller already gates on Number.isFinite, and
 * a NaN inside a path `d` is ignored by the renderer either way.
 */
export function projectY(v: number, frame: Frame): number {
  if (!Number.isFinite(v)) return Number.NaN;
  const range = frame.extent.max - frame.extent.min || 1;
  const clamped = Math.min(frame.extent.max, Math.max(frame.extent.min, v));
  return frame.height - ((clamped - frame.extent.min) / range) * frame.height;
}

/** projectY for a mirrored chart. `v` is the positive magnitude in both halves;
 *  the sign exists here and nowhere else. */
export function projectYSigned(v: number, frame: Frame, direction: "up" | "down" = "up"): number {
  return projectY(direction === "down" ? -v : v, frame);
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

// =============================================================================
// Axes
// -----------------------------------------------------------------------------
// A chart with no y scale answers "is that spike 40% or 4%" only by hovering it.
// These produce the tick VALUES; where they are drawn is MetricChart's problem,
// and the answer there is an HTML gutter rather than SVG text, because the
// viewBox is stretched horizontally and text inside it stretches with it.
// =============================================================================

/** 1, 2 or 5 times a power of ten. Anything else produces labels nobody can
 *  subdivide by eye: 0, 3.7, 7.4 is arithmetic, not a scale. */
const LADDER_DECIMAL = [1, 2, 5];

/**
 * Powers of two, because A BYTE AXIS IS NOT A DECIMAL ONE. fmt.bytes divides by
 * 1024, so a decimal-nice step lands the labels on values that are round in
 * base ten and ragged in the unit they are then printed in: a 16 GiB frame
 * stepped by 5e9 reads "0 B / 5 GB / 9 GB / 14 GB", which is not a scale, it is
 * a rounding artefact. Stepped by 4 GiB it reads "0 B / 4 GB / 8 GB / 12 GB /
 * 16 GB".
 */
const LADDER_BINARY = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512];

/**
 * A "nice" step for `base`. The rung chosen is the smallest one at or above the
 * raw step, so the result is always the COARSER of the two candidates: fewer,
 * further-apart labels, which is what a 90px chart can actually carry.
 */
function niceStep(raw: number, base = 10): number {
  if (!Number.isFinite(raw) || raw <= 0) return 1;
  const power = base ** Math.floor(Math.log(raw) / Math.log(base));
  const n = raw / power;
  for (const m of base === 1024 ? LADDER_BINARY : LADDER_DECIMAL) {
    if (n <= m) return m * power;
  }
  return base * power;
}

/**
 * Tick values covering `e`, at a nice step. `count` is a TARGET, not a promise:
 * pinning it exactly is what forces an unroundable step.
 *
 * `base` is 1024 for anything rendered through fmt.bytes or fmt.rate, and 10
 * for everything else. See LADDER_BINARY.
 */
export function niceTicks(e: Extent, count = 4, base = 10): number[] {
  const span = e.max - e.min;
  if (!Number.isFinite(span) || span <= 0) return [e.min];

  const step = niceStep(span / Math.max(1, count), base);
  const first = Math.ceil(e.min / step - 1e-9);
  const last = Math.floor(e.max / step + 1e-9);

  const out: number[] = [];
  // i * step, NOT v += step: repeated addition drifts, and the visible half of
  // that is a tick label reading "0.30000000000000004".
  for (let i = first; i <= last; i += 1) out.push(Number((i * step).toPrecision(12)));
  return out;
}

export interface AxisTickY {
  value: number;
  /** Frame units, WHICH ARE CSS PIXELS - see the banner. */
  y: number;
  /** Set where the tick sits on the frame's own edge, so the caller shifts the
   *  label inward instead of having it clipped in half. */
  edge: "top" | "bottom" | null;
}

export function yTicks(frame: Frame, count = 4, base = 10): AxisTickY[] {
  return niceTicks(frame.extent, count, base).map((value) => {
    const y = projectY(value, frame);
    return {
      value,
      y,
      edge: y <= 0.5 ? "top" : y >= frame.height - 0.5 ? "bottom" : null,
    };
  });
}

// =============================================================================
// Stacked areas
// -----------------------------------------------------------------------------
// One shared baseline, N bands accumulated on it. Used for memory, where the
// bands sum to MemTotal BY CONSTRUCTION and the frame is pinned to that total -
// which is the only arrangement in which a stack may claim to be the whole of
// something.
// =============================================================================

export interface StackBand {
  /** The ribbon between this band's cumulative top and the one below it. */
  d: string;
  /** The line along this band's own top edge, so adjacent bands are separated
   *  by a hairline as well as by brightness. Same gaps as `d`. */
  edge: string;
  /** Cumulative tops in frame units, NaN where the column is broken. The
   *  crosshair reads these: a dot placed at the band's own VALUE would sit at
   *  the height of 3 GB rather than on top of the 3 GB band. */
  tops: number[];
  label?: string;
  /** Position in the stack, 0 = bottom. Drives the opacity ramp. */
  index: number;
  /** Index into the array that was passed in, which is NOT `index`: an
   *  all-NaN band is dropped before stacking, so everything after it shifts.
   *  The crosshair needs the original to read that band's own value. */
  source: number;
}

export interface StackOptions {
  /**
   * Where a band has no value, break only the bands ABOVE it - the ones whose
   * baseline just became unknown - and keep the ones below, which are still
   * true. DEFAULT FALSE, which breaks the whole column, and that is right for a
   * stack filling to a fixed total: a partial stack under a pinned ceiling
   * reads as the total having collapsed.
   */
  partial?: boolean;
}

/**
 * N series accumulated on a shared baseline, bottom-first, one path per band.
 *
 * THE GAP RULE COMPOUNDS, AND THAT IS THE WHOLE POINT. `areaPath` breaks a fill
 * where its own series has a hole. Here a hole in the first band moves the
 * baseline of every band above it to somewhere nobody knows, so those break
 * too. Drawing them anyway would put the cache band at a plausible-looking
 * height that is simply wrong - a stack that lies, rather than a stack with a
 * hole in it.
 *
 * A band with NO finite point at all is a different finding: a resource this
 * host does not have (no swap device), not a gap. Those are dropped before
 * stacking, or one absent band would blank the entire chart. The caller must
 * not substitute zeros for them - zero swap and no swap are different things.
 *
 * The series need not share a points array but they must share timestamps,
 * which `onGrid` guarantees and which is why every lane on the System page is
 * fetched with one start/end/step.
 */
export function stackedAreaPaths(
  series: ChartSeries[],
  frame: Frame,
  options: StackOptions = {},
): StackBand[] {
  const live: { series: ChartSeries; source: number }[] = [];
  series.forEach((s, i) => {
    if (s.points.some(([, v]) => Number.isFinite(v))) live.push({ series: s, source: i });
  });
  if (!live.length) return [];

  const times = [...new Set(live.flatMap((l) => l.series.points.map((p) => p[0])))].sort((a, b) => a - b);
  // A Map keeps the LAST value for a duplicated timestamp; onGrid already
  // dedupes by bucket, which is why the contract above says onGrid first.
  const lookup = live.map((l) => new Map<number, number>(l.series.points));

  const xs = times.map((t) => projectX(t, frame, live[0].series.points));
  const tops: number[][] = live.map(() => []);

  for (let i = 0; i < times.length; i += 1) {
    let sum = 0;
    let broken = false;
    for (let k = 0; k < live.length; k += 1) {
      const v = lookup[k].get(times[i]);
      if (!Number.isFinite(v as number)) broken = true;
      if (!broken) sum += v as number;
      tops[k].push(broken ? Number.NaN : projectY(sum, frame));
    }
    if (!options.partial && broken) {
      for (let k = 0; k < live.length; k += 1) tops[k][i] = Number.NaN;
    }
  }

  const floor = xs.map(() => frame.height);
  return live.map((l, k) => {
    const base = k === 0 ? floor : tops[k - 1];
    const top = tops[k];
    const valid = top.map((y, i) => Number.isFinite(y) && Number.isFinite(base[i]));
    return {
      d: ribbonPath(xs, top, base, valid),
      edge: runLine(xs, top, valid),
      tops: top,
      label: l.series.label,
      index: k,
      source: l.source,
    };
  });
}

/** One polygon per contiguous run: out along the top, back along the baseline.
 *  A run of one sample is not an area, exactly as in areaPath. */
function ribbonPath(xs: number[], top: number[], base: number[], valid: boolean[]): string {
  let out = "";
  let i = 0;
  while (i < xs.length) {
    if (!valid[i]) {
      i += 1;
      continue;
    }
    let j = i;
    while (j + 1 < xs.length && valid[j + 1]) j += 1;
    if (j > i) {
      let d = `M${round(xs[i])} ${round(base[i])}`;
      for (let k = i; k <= j; k += 1) d += `L${round(xs[k])} ${round(top[k])}`;
      for (let k = j; k >= i; k -= 1) d += `L${round(xs[k])} ${round(base[k])}`;
      out += `${d}Z`;
    }
    i = j + 1;
  }
  return out;
}

function runLine(xs: number[], ys: number[], valid: boolean[]): string {
  let out = "";
  let open = false;
  for (let i = 0; i < xs.length; i += 1) {
    if (!valid[i]) {
      open = false;
      continue;
    }
    out += `${open ? "L" : "M"}${round(xs[i])} ${round(ys[i])}`;
    open = true;
  }
  return out;
}

/**
 * The extent a stack needs: the top of the tallest COMPLETE column, not the
 * tallest single band. `extent(series.flatMap(s => s.points))` is the bug this
 * exists to prevent - it would frame a 16 GB stack at the 8 GB of its largest
 * member and clip three quarters of the drawing.
 */
export function stackExtent(series: ChartSeries[], options: ExtentOptions = {}): Extent {
  const live = series.filter((s) => s.points.some(([, v]) => Number.isFinite(v)));
  const times = [...new Set(live.flatMap((s) => s.points.map((p) => p[0])))];
  const lookup = live.map((s) => new Map<number, number>(s.points));

  const totals: Point[] = times.map((t) => {
    let sum = 0;
    for (const m of lookup) {
      const v = m.get(t);
      if (!Number.isFinite(v as number)) return [t, Number.NaN] as Point;
      sum += v as number;
    }
    return [t, sum] as Point;
  });
  return extent(totals, options);
}

/**
 * The brightness ramp for stacked bands.
 *
 * BANDS ARE SEPARATED BY BRIGHTNESS OF ONE TONE, NEVER BY HUE. The design
 * system has exactly three status colours and a fourth would make the first
 * three mean less. Brightest at the bottom: that is the part actually in use,
 * and the eye should land there first. Five steps covers used / buffers /
 * cache / free plus swap.
 */
export const BAND_OPACITY = [0.42, 0.3, 0.2, 0.12, 0.07] as const;

export function bandOpacity(index: number): number {
  return BAND_OPACITY[Math.min(Math.max(index, 0), BAND_OPACITY.length - 1)];
}

/**
 * max(|v|) across every series, mirrored about zero.
 *
 * Both halves must be at ONE scale or the chart is a comparison shaped like a
 * lie: 6 MB/s in and 2 MB/s out, each drawn to its own extent, look identical.
 * `floorAtZero` is meaningless here and is ignored.
 */
export function symmetricExtent(series: ChartSeries[], options: ExtentOptions = {}): Extent {
  let m = 0;
  // A loop, not Math.max(...spread): seven series of 340 points is fine today
  // and a finer window is one edit away from blowing the argument limit.
  for (const s of series) {
    for (const [, v] of s.points) {
      if (Number.isFinite(v)) m = Math.max(m, Math.abs(v));
    }
  }

  const fixed = options.max;
  const top = Number.isFinite(fixed as number)
    ? (fixed as number)
    : m === 0
      ? 1
      : m * (1 + (options.pad ?? 0.08));
  return { min: -top, max: top };
}
