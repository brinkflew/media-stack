<script setup lang="ts">
/**
 * One chart, used at two sizes: the tall panel charts at the top of the System
 * page and the short lanes of the shared timeline below them.
 *
 * `preserveAspectRatio="none"` with a fixed viewBox is what lets the same
 * geometry stretch to whatever width the grid gives it, without recomputing
 * anything on resize. IT IS ALSO WHY THE CURSOR CANNOT BE READ IN VIEWBOX
 * UNITS: the mapping from user units to pixels is whatever the column happens
 * to be wide, so a pointer position has to come from the element's own bounding
 * rect. See onMove.
 */
import { computed, ref, useId } from "vue";
import {
  areaPath,
  extent,
  linePath,
  medianPath,
  projectX,
  projectY,
  sampleAt,
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
     *  the lanes - a 30px lane with gridlines is just noise. */
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
  },
);

const VIEW_W = 900;

const cross = useCrosshair();

const lines = computed<ChartSeries[]>(() =>
  props.series ?? [{ points: props.points ?? [], tone: props.tone }],
);

/** One extent across every series, or two cards on one chart could not be
 *  compared - which is the only reason to put them on one chart. */
const bounds = computed(() => extent(lines.value.flatMap((s) => s.points), { floorAtZero: props.floorAtZero }));

const frame = computed(() => ({
  width: VIEW_W,
  height: props.height,
  extent: bounds.value,
  from: props.from,
  to: props.to,
}));

/** The grid every series is on. They are fetched together, so the first one
 *  speaks for all of them. */
const grid = computed(() => lines.value[0]?.points ?? []);

const multi = computed(() => lines.value.length > 1);

const drawn = computed(() =>
  lines.value.map((s, i) => ({
    d: linePath(s.points, frame.value),
    stroke: `var(--${s.tone ?? props.tone})`,
    // Brightness separates overlapping lines. It is NOT a ranking - these are
    // the same measurement on two cards, and the readout names them in the same
    // order - so the step is gentle enough not to read as one being demoted.
    //
    // NOT DASHED. The dashed grey rule in every chart is the median, and a
    // dashed coloured line beside it reads as a second reference line rather
    // than as data.
    opacity: Math.max(0.5, 1 - i * 0.3),
  })),
);

/** Only for a single series: two translucent fills read as mud, and "the
 *  median of two cards" is not a quantity. */
const area = computed(() => (multi.value ? "" : areaPath(grid.value, frame.value)));
const mid = computed(() =>
  props.showMedian && !multi.value ? medianPath(grid.value, frame.value) : "",
);

const rules = computed(() =>
  Array.from({ length: props.grid }, (_, i) => ((i + 1) * props.height) / (props.grid + 1)),
);

const stroke = computed(() => `var(--${props.tone})`);

/** A gradient id has to be unique per instance or the first one on the page
 *  wins for every chart that references it. */
const gradientId = useId();

const empty = computed(() => !lines.value.some((s) => s.points.some(([, v]) => Number.isFinite(v))));

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

  return {
    x: projectX(t, frame.value, grid.value),
    // Mapped before filtering: a series whose sample is a hole must drop out
    // without shifting the tone of the ones after it.
    dots: lines.value
      .map((s) => ({ sample: sampleAt(s.points, t), tone: s.tone ?? props.tone, label: s.label }))
      .filter((d): d is { sample: Point; tone: "ok" | "warn" | "fail"; label: string | undefined } =>
        d.sample !== null && Number.isFinite(d.sample[1]),
      )
      .map((d) => ({
        y: projectY(d.sample[1], frame.value),
        fill: `var(--${d.tone})`,
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
  return {
    time: fmt.clock(t),
    rows: c.dots.map((d) => ({
      label: d.label,
      fill: d.fill,
      value: props.format ? props.format(d.value) : fmt.number(d.value),
    })),
  };
});

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
</script>

<template>
  <div
    class="wrap"
    :style="{ height: `${height}px` }"
    @pointermove="onMove"
    @pointerleave="over = false; cross.clear()"
    @pointercancel="over = false; cross.clear()"
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
        stroke-width="1.4"
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

    <!-- The readout. Positioned as a percentage of the wrapper rather than in
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
</template>

<style scoped>
.wrap {
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
</style>
