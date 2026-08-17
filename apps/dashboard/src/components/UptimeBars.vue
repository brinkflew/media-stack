<script setup lang="ts">
/**
 * Thirty days, one bar a day.
 *
 * THE GREY IS THE POINT. A day with no data is grey, never green - the store
 * only goes back as far as it goes, and a fresh Prometheus would otherwise
 * render a month of perfect uptime it has no evidence for. That is the same
 * mistake as an unrun check reading as a passing one.
 */
import { computed } from "vue";
import { dayStarts } from "@/uptime";
import { dayMonth, percent } from "@/format";

const props = defineProps<{
  /** One entry per day, oldest first. NaN where there is no data. */
  days: number[];
  /** Below this, a day counts as degraded; below half of it, as failing. */
  good?: number;
}>();

const good = computed(() => props.good ?? 0.999);

/** Thirty identical rectangles say nothing about which day they are. The title
 *  is the only affordance that names one, and it costs no layout. */
const bars = computed(() => {
  const starts = dayStarts(props.days.length);

  return props.days.map((ratio, i) => {
    const tone = !Number.isFinite(ratio)
      ? "off"
      : ratio >= good.value
        ? "ok"
        : ratio >= good.value / 2
          ? "warn"
          : "fail";
    const reading = Number.isFinite(ratio) ? percent(ratio, 2) : "no data";
    return { tone, title: `${dayMonth(starts[i])} - ${reading}` };
  });
});
</script>

<template>
  <div class="row">
    <div class="bars">
      <span
        v-for="(b, i) in bars"
        :key="i"
        class="bar"
        :title="b.title"
        :style="{ background: `var(--${b.tone})` }"
      />
    </div>
  </div>
</template>

<style scoped>
.row {
  min-width: 0;
}

.bars {
  display: flex;
  gap: 1.5px;
}

.bar {
  flex: 1;
  height: 12px;
  border-radius: 1px;
  min-width: 2px;
}
</style>
