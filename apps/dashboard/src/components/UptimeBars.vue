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
import { useTooltip } from "@/composables/useTooltip";

const tip = useTooltip();

const props = defineProps<{
  /** One entry per day, oldest first. NaN where there is no data. */
  days: number[];
  /** Below this, a day counts as degraded; below half of it, as failing. */
  good?: number;
}>();

const good = computed(() => props.good ?? 0.999);

/**
 * Thirty identical rectangles say nothing about which day they are, and naming
 * one is the whole reason this had a native `title` first. It is a real tooltip
 * now because the grey needs a sentence, not a date: "no data" beside a green
 * neighbour reads as an outage unless something says the store simply does not
 * go back that far.
 *
 * Thirty bars is NOT thirty tab stops. The strip is one, and each bar keeps a
 * pointer tooltip - the same trade the rack rows make with their LEDs.
 */
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
    const known = Number.isFinite(ratio);
    return {
      tone,
      day: dayMonth(starts[i]),
      content: {
        title: dayMonth(starts[i]),
        lines: [known ? `${percent(ratio, 2)} up` : "no data"],
        caveat: known
          ? undefined
          : "Grey is missing history, not downtime. The store only goes back as far as it goes.",
      },
    };
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
        v-bind="tip.hover(`up-${i}`, b.content)"
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
