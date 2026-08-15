<script setup lang="ts">
/**
 * The 24-bar activity strip in the pod rack. Deliberately not a chart: it has
 * no axis and no scale, and it is not meant to be read as a number - it exists
 * so that a row which has been busy looks different from one that has been
 * idle, at a glance, down a column of sixteen.
 *
 * A missing sample is a gap at the floor rather than a zero-height bar, so an
 * absent series does not look like an idle one.
 */
import { computed } from "vue";

const props = withDefaults(
  defineProps<{
    /** Any scale. Normalised against the largest value present. */
    values: number[];
    tone?: "ok" | "warn" | "fail" | "off";
    height?: number;
  }>(),
  { tone: "ok", height: 20 },
);

const bars = computed(() => {
  const finite = props.values.filter(Number.isFinite);
  const max = finite.length ? Math.max(...finite) : 0;

  return props.values.map((v) => {
    if (!Number.isFinite(v)) return { h: 0, missing: true };
    if (max <= 0) return { h: 1, missing: false };
    // A floor of 1px so a small-but-nonzero value is still visible.
    return { h: Math.max(1, (v / max) * props.height), missing: false };
  });
});
</script>

<template>
  <div class="strip" :style="{ height: `${height}px` }">
    <span
      v-for="(b, i) in bars"
      :key="i"
      class="bar"
      :class="{ missing: b.missing }"
      :style="{ height: `${b.h}px`, background: `var(--${tone})` }"
    />
  </div>
</template>

<style scoped>
.strip {
  display: flex;
  align-items: flex-end;
  gap: 2px;
}

.bar {
  width: 3px;
  flex: none;
  border-radius: 1px;
  opacity: 0.85;
}

.missing {
  height: 2px !important;
  background: var(--off) !important;
  opacity: 1;
}
</style>
