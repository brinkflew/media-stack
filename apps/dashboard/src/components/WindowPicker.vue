<script setup lang="ts">
/**
 * The 1h / 6h / 24h / 7d picker.
 *
 * Extracted because SystemPage and ServicesPage carried byte-identical copies of
 * this markup AND of its three CSS rules. It takes no props and emits nothing:
 * useTimeWindow() is a module-level singleton, so every instance is already
 * looking at and setting the same choice, which is what makes the selection
 * survive a route change.
 *
 * Belongs inside a `<Teleport defer to="#toolbar">` in the page that uses it.
 */
import { useTimeWindow } from "@/composables/useTimeWindow";

const { windows, active, setWindow } = useTimeWindow();
</script>

<template>
  <div class="picker">
    <button
      v-for="w in windows"
      :key="w.id"
      class="pick mono"
      :class="{ on: active === w.id }"
      @click="setWindow(w.id)"
    >
      {{ w.label }}
    </button>
  </div>
</template>

<style scoped>
/* Byte-identical to the copies this replaced in SystemPage.vue and
   ServicesPage.vue, which were themselves byte-identical to each other. */
.picker {
  display: flex;
  gap: 2px;
  padding: 2px;
  border-radius: var(--r-sm);
  background: var(--field);
  border: 1px solid var(--line);
}

.pick {
  padding: 5px 11px;
  border-radius: var(--r-xs);
  font: var(--t-mono-md);
  color: var(--fg-5);
}

.pick:hover {
  color: var(--fg);
}

.pick.on {
  background: oklch(1 0 0 / 0.09);
  color: var(--fg);
}
</style>
