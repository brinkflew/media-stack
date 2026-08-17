<script setup lang="ts">
/**
 * The one-line staleness reason for a section that is NOT inside a PanelBox.
 *
 * PanelBox already prints its `stale` reason in its own header. Sections that sit
 * on the page ground rather than in a panel - ServicesPage's rack, Home's
 * recently-added grid, Library's table - had to hand-roll the same `v-if` and the
 * same two CSS rules each time. Four copies of a sentence whose whole job is to
 * be noticed is how it stops being noticed.
 *
 * It renders NOTHING when `reason` is null, so a caller can bind it
 * unconditionally. Amber rather than red on purpose: stale data is degraded, not
 * failed, and the three status colours mean what they say.
 */
defineProps<{
  /** The reason, or null when current. Not a boolean - the sentence is the point. */
  reason: string | null;
}>();
</script>

<template>
  <p v-if="reason" class="stale mono">{{ reason }}</p>
</template>

<style scoped>
.stale {
  font: var(--t-mono-sm);
  color: var(--warn);
}
</style>
