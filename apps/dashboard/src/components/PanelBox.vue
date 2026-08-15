<script setup lang="ts">
/**
 * The panel: a label, an optional right-hand aside, and a body.
 *
 * `stale` is not decoration. When the data behind a panel has stopped being
 * refreshed the panel dims and says so, rather than continuing to render a
 * confident number that is an hour old. Every page is expected to pass it.
 */
withDefaults(
  defineProps<{
    label?: string;
    /** Dim the body and show why. Pass the reason, not just a boolean. */
    stale?: string | null;
    /** Sunken surface, for the panels the design draws darker. */
    sunken?: boolean;
    padding?: string;
  }>(),
  { label: "", stale: null, sunken: false, padding: "13px" },
);
</script>

<template>
  <section class="panel" :class="{ sunken }" :style="{ padding }">
    <header v-if="label || $slots.aside" class="head">
      <span class="label">{{ label }}</span>
      <span class="aside"><slot name="aside" /></span>
    </header>

    <div class="body" :class="{ dim: !!stale }">
      <slot />
    </div>

    <p v-if="stale" class="stale mono">{{ stale }}</p>
  </section>
</template>

<style scoped>
.panel {
  background: var(--surface-raised);
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  min-width: 0;
}

.sunken {
  background: var(--surface-sunken);
}

.head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 11px;
}

.aside {
  font: var(--t-mono-sm);
  color: var(--fg-5);
}

.body {
  min-width: 0;
}

/* Dimmed, not hidden. The last known value is still the most useful thing on
   screen; what changes is that it no longer claims to be current. */
.dim {
  opacity: 0.4;
  filter: saturate(0.5);
}

.stale {
  margin-top: 10px;
  padding-top: 9px;
  border-top: 1px solid var(--line);
  font: var(--t-mono-sm);
  color: var(--warn);
}
</style>
