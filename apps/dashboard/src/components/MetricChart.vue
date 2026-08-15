<script setup lang="ts">
/**
 * One chart, used at two sizes: the tall panel charts at the top of the System
 * page and the short lanes of the shared timeline below them.
 *
 * `preserveAspectRatio="none"` with a fixed viewBox is what lets the same
 * geometry stretch to whatever width the grid gives it, without recomputing
 * anything on resize.
 */
import { computed } from "vue";
import { areaPath, extent, linePath, medianPath, type Point } from "@/charts";

const props = withDefaults(
  defineProps<{
    points: Point[];
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
  }>(),
  {
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

const bounds = computed(() => extent(props.points, { floorAtZero: props.floorAtZero }));

const frame = computed(() => ({
  width: VIEW_W,
  height: props.height,
  extent: bounds.value,
  from: props.from,
  to: props.to,
}));

const line = computed(() => linePath(props.points, frame.value));
const area = computed(() => areaPath(props.points, frame.value));
const mid = computed(() => (props.showMedian ? medianPath(props.points, frame.value) : ""));

const rules = computed(() =>
  Array.from({ length: props.grid }, (_, i) => ((i + 1) * props.height) / (props.grid + 1)),
);

const stroke = computed(() => `var(--${props.tone})`);

/** A gradient id has to be unique per instance or the first one on the page
 *  wins for every chart that references it. */
const gradientId = computed(() => `fill-${props.tone}-${Math.round(props.height)}`);

const empty = computed(() => !props.points.some(([, v]) => Number.isFinite(v)));
</script>

<template>
  <div class="wrap" :style="{ height: `${height}px` }">
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
        v-if="line"
        :d="line"
        fill="none"
        :stroke="stroke"
        stroke-width="1.4"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>

    <!-- Not an empty frame: an empty frame reads as a flat line at zero. -->
    <span v-if="empty" class="empty mono">no data in this window</span>
  </div>
</template>

<style scoped>
.wrap {
  position: relative;
  width: 100%;
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
</style>
