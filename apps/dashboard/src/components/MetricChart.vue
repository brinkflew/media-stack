<script setup lang="ts">
/**
 * One chart, used at three sizes: the tall cards at the top of the System page,
 * the short lanes of the shared timeline below them, and anything in between.
 *
 * `preserveAspectRatio="none"` with a fixed viewBox is what lets the same
 * geometry stretch to whatever width the grid gives it, without recomputing
 * anything on resize. IT IS ALSO WHY THE CURSOR CANNOT BE READ IN VIEWBOX
 * UNITS: the mapping from user units to pixels is whatever the column happens
 * to be wide, so a pointer position has to come from the element's own bounding
 * rect. See onMove.
 *
 * THE VERTICAL AXIS IS NOT STRETCHED, AND THAT ASYMMETRY IS THE WHOLE REASON
 * THE Y AXIS IS CHEAP. The element is `height` CSS pixels tall and the viewBox
 * is `height` user units tall, so one vertical user unit is exactly one pixel:
 * an HTML label at `top: <y>px` in the gutter lands on the rule drawn at
 * `y=<y>` in the SVG, with no measurement and no second source of truth. The x
 * labels get no such gift and are positioned by percentage.
 *
 * THE POINTER TARGET IS `.plot`, NEVER `.frame`. The frame now includes a
 * left gutter, and a getBoundingClientRect taken on it would skew every
 * reported time by gutter/plotWidth of the window - 46px of a 600px panel on a
 * 6h window is 28 minutes, in the direction of "the spike was earlier than it
 * was", which is exactly the kind of wrong that looks plausible.
 */
import { computed, ref, useId } from "vue";
import {
  areaPath,
  bandOpacity,
  extent,
  linePath,
  latest,
  medianPath,
  projectX,
  projectY,
  projectYSigned,
  sampleAt,
  stackExtent,
  stackedAreaPaths,
  symmetricExtent,
  yTicks,
  type AxisTickY,
  type ChartSeries,
  type Point,
} from "@/charts";
import { useCrosshair } from "@/composables/useCrosshair";
import * as fmt from "@/format";

const props = withDefaults(
  defineProps<{
    /** The single-series shorthand, which is what most call sites want. */
    points?: Point[];
    /** More than one line, sharing one y-scale. Wins over `points`. */
    series?: ChartSeries[];
    tone?: "ok" | "warn" | "fail";
    height?: number;
    /** Horizontal rules. The design draws three on the tall charts, none on
     *  the lanes - a 30px lane with gridlines is just noise. With `yAxis` on
     *  this becomes the TICK TARGET and the rules move onto the tick values,
     *  because a labelled tick naming a rule that is somewhere else is worse
     *  than no rule at all. */
    grid?: number;
    showMedian?: boolean;
    from?: number;
    to?: number;
    /** Off for anything that does not naturally start at zero, e.g. a
     *  temperature. On for everything else - see charts.ts. */
    floorAtZero?: boolean;
    /** How to render the readout's value. Passed in rather than inferred: this
     *  component draws bytes, ratios, degrees and rates, and a number shown in
     *  the wrong unit is the failure this repository keeps naming. */
    format?: (v: number) => string;
    /** A labelled y scale in a left gutter. Renders NOTHING without `format`:
     *  the fallback is fmt.number(v, 0), which labels every tick on a ratio
     *  chart "0" or "1", and a missing axis is a smaller lie than a wrong one. */
    yAxis?: boolean;
    /** Time ticks under the plot. Off on the shared timeline, whose header
     *  already carries one axis for every lane at once. */
    xAxis?: boolean;
    xTicks?: number;
    /** The base the y ticks step in: 1024 for anything drawn through fmt.bytes
     *  or fmt.rate, 10 for everything else. A byte axis stepped in base ten
     *  gets labels that are round before the unit conversion and ragged after
     *  it - "0 B / 5 GB / 9 GB / 14 GB" on a 16 GiB frame. */
    tickBase?: number;
    /**
     * Pin the top of the frame: CPU to 1, memory to MemTotal. Ignored when not
     * finite, so a ceiling that has not loaded yet falls back to the data's own
     * extent rather than collapsing the chart.
     *
     * A SAMPLE ABOVE THE CEILING WELDS TO THE TOP EDGE and reads as "steady at
     * max" - this is the first place projectY's clamp actually bites, because
     * until now the extent always came from the data. The readout still reports
     * the raw value, so the dot and the number visibly disagree. That is the
     * least-bad outcome and it is deliberate: do not clamp the readout to match.
     */
    yMax?: number;
    yMin?: number;
    /** Accumulate the series on a shared baseline instead of overlaying them.
     *  Only honest with a `yMax` naming the total the bands add up to. */
    stacked?: boolean;
    /** Name the bands under the chart. A stack whose bands are unlabelled is
     *  four shades of teal. */
    legend?: boolean;
    /** Draw `direction: "down"` series below a zero rule, at the same scale as
     *  the upward ones. The y labels read as ABSOLUTE values in both halves:
     *  the bottom half is "out", not "negative". */
    mirror?: boolean;
  }>(),
  {
    points: undefined,
    series: undefined,
    tone: "ok",
    height: 72,
    grid: 0,
    showMedian: false,
    floorAtZero: true,
    from: undefined,
    to: undefined,
    format: undefined,
    yAxis: false,
    xAxis: false,
    xTicks: 5,
    tickBase: 10,
    yMax: undefined,
    yMin: undefined,
    stacked: false,
    legend: false,
    mirror: false,
  },
);

const VIEW_W = 900;
const Y_GUTTER = 46;

const cross = useCrosshair();

const lines = computed<ChartSeries[]>(() =>
  props.series ?? [{ points: props.points ?? [], tone: props.tone }],
);

const fixed = computed(() => ({
  max: Number.isFinite(props.yMax as number) ? props.yMax : undefined,
  min: Number.isFinite(props.yMin as number) ? props.yMin : undefined,
}));

/** One extent across every series, or two cards on one chart could not be
 *  compared - which is the only reason to put them on one chart. */
const bounds = computed(() => {
  if (props.mirror) return symmetricExtent(lines.value, { max: fixed.value.max });
  if (props.stacked) return stackExtent(lines.value, { max: fixed.value.max, min: fixed.value.min });
  return extent(lines.value.flatMap((s) => s.points), {
    floorAtZero: props.floorAtZero,
    max: fixed.value.max,
    min: fixed.value.min,
  });
});

const frame = computed(() => ({
  width: VIEW_W,
  height: props.height,
  extent: bounds.value,
  from: props.from,
  to: props.to,
}));

/** The grid every series is on. They are fetched together, so any of them
 *  speaks for all of them - but the LONGEST one is taken rather than the first,
 *  because a mirrored chart whose upward half is absent would otherwise snap
 *  the cursor against an empty array. */
const grid = computed<Point[]>(() => {
  let best: Point[] = [];
  for (const s of lines.value) if (s.points.length > best.length) best = s.points;
  return best;
});

const multi = computed(() => lines.value.length > 1);

const bands = computed(() => (props.stacked ? stackedAreaPaths(lines.value, frame.value) : []));

/** The only place the mirror's sign exists. Everything else - peak, median,
 *  latest, the readout - keeps positive magnitudes. */
function signed(s: ChartSeries): Point[] {
  return s.direction === "down" ? s.points.map(([t, v]) => [t, -v] as Point) : s.points;
}

const drawn = computed(() =>
  props.stacked
    ? []
    : lines.value.map((s, i) => ({
        d: linePath(signed(s), frame.value),
        stroke: `var(--${s.tone ?? props.tone})`,
        // Brightness separates overlapping lines. It is NOT a ranking - these
        // are the same measurement on two cards, and the readout names them in
        // the same order - so the step is gentle enough not to read as one
        // being demoted.
        //
        // A MIRRORED PAIR IS SEPARATED BY POSITION, NOT BRIGHTNESS. Dimming the
        // downward half would say it matters less.
        //
        // A SERIES MAY OVERRIDE THE RAMP, and the CPU card is why: twelve cores
        // are twelve of the same thing, so they take one flat opacity and the
        // mean takes full weight over them. A ramp there would rank them.
        //
        // NOT DASHED. The dashed grey rule in every chart is the median, and a
        // dashed coloured line beside it reads as a second reference line
        // rather than as data.
        opacity: s.opacity ?? (props.mirror ? 1 : Math.max(0.5, 1 - i * 0.3)),
        width: s.width ?? 1.4,
      })),
);

/** Only for a single, unstacked series: two translucent fills read as mud, and
 *  "the median of a stack" is not a quantity. */
const area = computed(() => (multi.value || props.stacked ? "" : areaPath(grid.value, frame.value)));
const mid = computed(() =>
  props.showMedian && !multi.value && !props.stacked && !props.mirror
    ? medianPath(grid.value, frame.value)
    : "",
);

const stroke = computed(() => `var(--${props.tone})`);

/** A gradient id has to be unique per instance or the first one on the page
 *  wins for every chart that references it. */
const gradientId = useId();

const empty = computed(() =>
  props.stacked
    ? bands.value.every((b) => !b.d)
    : !lines.value.some((s) => s.points.some(([, v]) => Number.isFinite(v))),
);

// ---------------------------------------------------------------------------
// Axes
// ---------------------------------------------------------------------------
const showYAxis = computed(() => props.yAxis && typeof props.format === "function");

/** Gated on `empty`: a dead chart printing a confident 0/25/50/75/100 scale
 *  around "no data in this window" reads worse than an empty frame does. The X
 *  axis is NOT gated the same way - the window is a real fact even when the
 *  data is not. */
const ticksY = computed<AxisTickY[]>(() => {
  if (!showYAxis.value || empty.value) return [];
  const all = yTicks(frame.value, props.grid || 4, props.tickBase);
  // On a mirrored chart the zero rule labels itself, so a "0" in the gutter is
  // a third thing saying the same one.
  return props.mirror ? all.filter((t) => t.value !== 0) : all;
});

/**
 * The rules the chart draws. With a y axis they ARE the tick values, or the
 * labels name lines that are somewhere else. Without one they stay the even
 * divisions of the height that every existing caller already gets.
 *
 * A tick on the frame's own edge keeps its label and loses its rule: a line at
 * y = height is a border, not a gridline.
 */
const rules = computed<number[]>(() => {
  if (showYAxis.value && ticksY.value.length) {
    return ticksY.value.filter((t) => t.edge === null).map((t) => t.y);
  }
  return Array.from({ length: props.grid }, (_, i) => ((i + 1) * props.height) / (props.grid + 1));
});

const ticksX = computed(() => {
  if (!props.xAxis || props.from === undefined || props.to === undefined) return [];
  const from = props.from;
  const span = props.to - from || 1;
  const all = fmt.axisTicks(from, props.to, props.xTicks);
  return all.map((t, i) => ({
    ...t,
    left: `${(((t.at - from) / span) * 100).toFixed(3)}%`,
    first: i === 0,
    last: i === all.length - 1,
  }));
});

/** Through `format`, always. An axis labelled in the wrong unit is the same
 *  failure as a readout labelled in the wrong unit, and larger, because it is
 *  on screen at all times rather than under a cursor. */
function tickLabel(v: number): string {
  const n = props.mirror ? Math.abs(v) : v;
  return props.format ? props.format(n) : fmt.number(n);
}

/** Where zero falls. Exactly height/2 under a symmetric extent, but computed
 *  rather than assumed so a fixed asymmetric ceiling still lands right. */
const zeroY = computed(() => (props.mirror && !empty.value ? projectY(0, frame.value) : null));

/**
 * The cursor, which comes from a module-level ref rather than from this
 * component's own hover: every lane is on the same axis, so hovering one must
 * mark the same instant on all of them. A window that does not contain the
 * hovered time draws nothing.
 */
const cursor = computed(() => {
  const t = cross.at.value;
  if (t === null || props.from === undefined || props.to === undefined) return null;
  if (t < props.from || t > props.to) return null;

  const x = projectX(t, frame.value, grid.value);

  if (props.stacked) {
    // A DOT AT THE BAND'S OWN VALUE WOULD SIT AT THE HEIGHT OF 3 GB rather than
    // on top of the 3 GB band, so the y comes from the cumulative tops.
    const nearest = sampleAt(grid.value, t);
    const i = nearest ? grid.value.findIndex((p) => p[0] === nearest[0]) : -1;
    if (i < 0) return { x, dots: [] };

    const dots = bands.value.map((b) => ({
      y: b.tops[i],
      fill: stroke.value,
      opacity: bandOpacity(b.index),
      value: sampleAt(lines.value[b.source].points, t)?.[1] ?? Number.NaN,
      label: b.label,
    }));

    // A THREE-DOT COLUMN FOR A FOUR-BAND STACK reads as the total having
    // dropped. If any band is a hole here, the whole column is unknown.
    if (dots.some((d) => !Number.isFinite(d.y) || !Number.isFinite(d.value))) return { x, dots: [] };
    return { x, dots };
  }

  return {
    x,
    // Mapped before filtering: a series whose sample is a hole must drop out
    // without shifting the tone of the ones after it.
    dots: lines.value
      .map((s) => ({ sample: sampleAt(s.points, t), tone: s.tone ?? props.tone, label: s.label, direction: s.direction }))
      .filter(
        (d): d is {
          sample: Point;
          tone: "ok" | "warn" | "fail";
          label: string | undefined;
          direction: "up" | "down" | undefined;
        } => d.sample !== null && Number.isFinite(d.sample[1]),
      )
      .map((d) => ({
        y: projectYSigned(d.sample[1], frame.value, d.direction ?? "up"),
        fill: `var(--${d.tone})`,
        opacity: 1,
        // The VALUE, not only its position. This was already computed and
        // thrown away: the comment on onMove promises that "the rule, the dot
        // and the readout all name the same instant", and until now there was
        // no readout for it to be true of.
        value: d.sample[1],
        label: d.label,
      })),
  };
});

/** Only the lane actually under the pointer draws the readout. The crosshair
 *  itself is deliberately on every lane at once - that is what a shared time
 *  axis is for - but twelve readout boxes stacked down the page is not a
 *  reading, it is a wall. */
const over = ref(false);

/**
 * The readout's text. `format` is a prop rather than a guess: this component
 * draws bytes, ratios, degrees and rates, and a number rendered in the wrong
 * unit is exactly the failure this repository keeps naming.
 */
const readout = computed(() => {
  const c = cursor.value;
  const t = cross.at.value;
  if (!c || t === null || !c.dots.length) return null;

  const rows = c.dots.map((d) => ({
    label: d.label,
    fill: d.fill,
    opacity: d.opacity,
    value: props.format ? props.format(d.value) : fmt.number(d.value),
  }));

  // With a pinned ceiling the total is what the chart is about, and it is the
  // one number a stack does not otherwise state anywhere.
  if (props.stacked) {
    const total = c.dots.reduce((sum, d) => sum + d.value, 0);
    rows.push({
      label: "total",
      fill: "var(--fg-3)",
      opacity: 1,
      value: props.format ? props.format(total) : fmt.number(total),
    });
  }

  return { time: fmt.clock(t), rows };
});

/** Top band first, so the list reads down in the order the bands are drawn up.
 *  The swatch opacity is the same bandOpacity the fill uses, so the legend
 *  cannot drift from the drawing. */
const legendRows = computed(() =>
  lines.value
    .map((s, i) => ({
      label: s.label ?? `band ${i}`,
      opacity: bandOpacity(i),
      value: props.format
        ? props.format(
            cross.at.value === null
              ? latest(s.points)
              : (sampleAt(s.points, cross.at.value)?.[1] ?? Number.NaN),
          )
        : "",
    }))
    .reverse(),
);

function onMove(event: PointerEvent): void {
  over.value = true;
  if (props.from === undefined || props.to === undefined) return;

  const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
  if (rect.width <= 0) return;

  const fraction = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
  const t = props.from + fraction * (props.to - props.from);

  // Snap to a real sample so the rule, the dot and the readout all name the
  // same instant instead of three neighbouring ones.
  const nearest = sampleAt(grid.value, t);
  cross.setAt(nearest ? nearest[0] : t);
}

function onLeave(): void {
  over.value = false;
  cross.clear();
}
</script>

<template>
  <div class="frame" :style="{ '--y-gutter': showYAxis ? `${Y_GUTTER}px` : '0px' }">
    <!-- Absolutely positioned inside a gutter of exactly `height` px, because a
         vertical frame unit is a CSS pixel. NOT grid rows: nice ticks are not
         evenly spaced, and even spacing is the thing being removed. -->
    <div v-if="showYAxis" class="y-axis" :style="{ height: `${height}px` }" aria-hidden="true">
      <span
        v-for="t in ticksY"
        :key="t.value"
        class="y-tick mono"
        :class="t.edge"
        :style="{ top: `${t.y}px` }"
        >{{ tickLabel(t.value) }}</span
      >
    </div>

    <div
      class="plot"
      :style="{ height: `${height}px` }"
      @pointermove="onMove"
      @pointerleave="onLeave"
      @pointercancel="onLeave"
    >
      <svg
        :viewBox="`0 0 ${VIEW_W} ${height}`"
        preserveAspectRatio="none"
        class="chart"
        role="img"
        aria-hidden="true"
      >
        <defs>
          <linearGradient :id="gradientId" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" :stop-color="stroke" stop-opacity="0.22" />
            <stop offset="100%" :stop-color="stroke" stop-opacity="0.02" />
          </linearGradient>
        </defs>

        <line
          v-for="y in rules"
          :key="y"
          x1="0"
          :y1="y"
          :x2="VIEW_W"
          :y2="y"
          stroke="oklch(1 0 0 / 0.05)"
          stroke-width="1"
          vector-effect="non-scaling-stroke"
        />

        <!-- Solid and brighter than a gridline, so it is never mistaken for one
             or for the dashed median. Hidden when empty: a confident line
             through the middle of a chart with no data is exactly the "flat
             line at zero" the empty message exists to prevent. -->
        <line
          v-if="zeroY !== null"
          x1="0"
          :y1="zeroY"
          :x2="VIEW_W"
          :y2="zeroY"
          stroke="var(--line-strong)"
          stroke-width="1"
          vector-effect="non-scaling-stroke"
        />

        <g v-if="stacked">
          <path
            v-for="b in bands"
            :key="b.index"
            :d="b.d"
            :fill="stroke"
            :opacity="bandOpacity(b.index)"
          />
          <path
            v-for="b in bands"
            :key="`e${b.index}`"
            :d="b.edge"
            fill="none"
            :stroke="stroke"
            stroke-width="1"
            :opacity="Math.min(0.55, bandOpacity(b.index) + 0.18)"
            vector-effect="non-scaling-stroke"
          />
        </g>

        <path v-if="area" :d="area" :fill="`url(#${gradientId})`" />
        <path
          v-if="mid"
          :d="mid"
          fill="none"
          stroke="var(--fg-5)"
          stroke-width="1"
          stroke-dasharray="4 4"
          vector-effect="non-scaling-stroke"
        />
        <path
          v-for="(l, i) in drawn"
          :key="i"
          :d="l.d"
          fill="none"
          :stroke="l.stroke"
          :stroke-width="l.width"
          stroke-linejoin="round"
          stroke-linecap="round"
          :opacity="l.opacity"
          vector-effect="non-scaling-stroke"
        />

        <!-- The cursor, drawn last so it sits over the lines it is reading. -->
        <g v-if="cursor">
          <line
            :x1="cursor.x"
            y1="0"
            :x2="cursor.x"
            :y2="height"
            stroke="var(--fg-5)"
            stroke-width="1"
            vector-effect="non-scaling-stroke"
          />
          <!-- Non-scaling stroke keeps the ring round; the fill would still be an
               ellipse under a stretched viewBox, so the dot is drawn unfilled. -->
          <circle
            v-for="(d, i) in cursor.dots"
            :key="i"
            :cx="cursor.x"
            :cy="d.y"
            r="2.5"
            fill="none"
            :stroke="d.fill"
            stroke-width="2"
            vector-effect="non-scaling-stroke"
          />
        </g>
      </svg>

      <!-- Not an empty frame: an empty frame reads as a flat line at zero. -->
      <span v-if="empty" class="empty mono">no data in this window</span>

      <!-- The readout. Positioned as a percentage of the PLOT rather than in
           viewBox units, for the same reason onMove reads getBoundingClientRect:
           the viewBox is stretched, so a user-unit x means nothing in CSS. -->
      <div
        v-if="over && cursor && readout"
        class="readout mono"
        :style="{ left: `${(cursor.x / VIEW_W) * 100}%` }"
      >
        <div class="r-time">{{ readout.time }}</div>
        <div v-for="(d, i) in readout.rows" :key="i" class="r-row">
          <span v-if="d.label" class="r-label">{{ d.label }}</span>
          <span class="r-value" :style="{ color: d.fill }">{{ d.value }}</span>
        </div>
      </div>
    </div>

    <div v-if="ticksX.length" class="x-axis" aria-hidden="true">
      <span
        v-for="(t, i) in ticksX"
        :key="i"
        class="x-tick mono"
        :class="{ first: t.first, last: t.last }"
        :style="{ left: t.left }"
      >
        <!-- The day slot is always rendered, empty where the date has not
             changed, so the times stay on one baseline across the row. -->
        <span class="x-day">{{ t.day ?? "" }}</span>
        <span>{{ t.time }}</span>
      </span>
    </div>

    <ul v-if="legend" class="legend mono">
      <li v-for="r in legendRows" :key="r.label">
        <span class="swatch" :style="{ background: stroke, opacity: r.opacity }" />
        <span class="l-name">{{ r.label }}</span>
        <span class="l-value">{{ r.value }}</span>
      </li>
    </ul>
  </div>
</template>

<style scoped>
/* minmax(0, 1fr), NOT 1fr: an svg with width:100% has a min-content
   contribution, and a bare 1fr track lets it push the column wider than the
   panel on the first paint.

   THE GUTTER IS A FIXED WIDTH, NEVER `auto`. Every lane of the shared timeline
   must share one x-mapping; a content-sized gutter would give the CPU lane
   ("100%") and a memory lane ("14.2 GB") different widths, every plot would
   start at a different x, and the shared time axis would silently stop being
   shared. */
.frame {
  display: grid;
  grid-template-columns: var(--y-gutter, 0px) minmax(0, 1fr);
  min-width: 0;
}

.y-axis {
  grid-column: 1;
  grid-row: 1;
  position: relative;
}

.y-tick {
  position: absolute;
  right: 6px;
  transform: translateY(-50%);
  font: var(--t-mono-xs);
  color: var(--fg-dim);
  white-space: nowrap;
}

/* A tick welded to the frame's own edge - which is what a fixed ceiling
   guarantees - would otherwise be clipped in half by whatever sits above. */
.y-tick.top {
  transform: translateY(0);
}

.y-tick.bottom {
  transform: translateY(-100%);
}

.plot {
  grid-column: 2;
  grid-row: 1;
  position: relative;
  width: 100%;
  /* Reads a horizontal drag as a cursor move while leaving the page free to
     scroll vertically under a finger. */
  touch-action: pan-y;
}

.chart {
  display: block;
  width: 100%;
  height: 100%;
  overflow: visible;
}

.x-axis {
  grid-column: 2;
  grid-row: 2;
  position: relative;
  height: 26px;
}

.x-tick {
  position: absolute;
  top: 4px;
  display: flex;
  flex-direction: column;
  align-items: center;
  transform: translateX(-50%);
  font: var(--t-mono-xs);
  color: var(--fg-dim);
  line-height: 1.35;
  white-space: nowrap;
}

.x-tick.first {
  transform: translateX(0);
}

.x-tick.last {
  transform: translateX(-100%);
}

/* Brighter than the time it sits above: the date is the rarer, more orienting
   half. Empty on most ticks, where it only holds the baseline. */
.x-day {
  color: var(--fg-4);
  min-height: 1.35em;
}

.empty {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  font: var(--t-mono-sm);
  color: var(--fg-dim);
  pointer-events: none;
}

/* Follows the crosshair, clamped inside the lane by a translate that flips
   past the midpoint - a box that ran off the right edge of a 900-unit chart
   would be unreadable exactly where the newest data is. */
.readout {
  position: absolute;
  top: 2px;
  transform: translateX(-50%);
  padding: 4px 7px;
  border-radius: var(--r-xs);
  background: var(--surface-high);
  border: 1px solid var(--line-strong);
  pointer-events: none;
  white-space: nowrap;
  max-width: 45%;
  z-index: 1;
}

.r-time {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.r-row {
  display: flex;
  gap: 8px;
  justify-content: space-between;
}

.r-label {
  font: var(--t-mono-xs);
  color: var(--fg-5);
}

.r-value {
  font: var(--t-mono-sm);
}

.legend {
  grid-column: 1 / -1;
  grid-row: 3;
  display: flex;
  flex-wrap: wrap;
  gap: 4px 14px;
  margin-top: 9px;
}

.legend li {
  display: flex;
  align-items: center;
  gap: 6px;
  font: var(--t-mono-xs);
}

.swatch {
  width: 8px;
  height: 8px;
  border-radius: 2px;
  flex: none;
}

.l-name {
  color: var(--fg-5);
}

.l-value {
  color: var(--fg-3);
}
</style>
