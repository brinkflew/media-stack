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

const props = defineProps<{
  /** One entry per day, oldest first. NaN where there is no data. */
  days: number[];
  /** Below this, a day counts as degraded; below half of it, as failing. */
  good?: number;
}>();

const good = computed(() => props.good ?? 0.999);

const bars = computed(() =>
  props.days.map((ratio) => {
    if (!Number.isFinite(ratio)) return "off";
    if (ratio >= good.value) return "ok";
    if (ratio >= good.value / 2) return "warn";
    return "fail";
  }),
);

</script>

<template>
  <div class="row">
    <div class="bars">
      <span v-for="(tone, i) in bars" :key="i" class="bar" :style="{ background: `var(--${tone})` }" />
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
