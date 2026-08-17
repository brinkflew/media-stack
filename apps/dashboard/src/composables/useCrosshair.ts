// =============================================================================
// The shared cursor
// -----------------------------------------------------------------------------
// One instant, module-level, for every chart on the page - the same shape as
// useTimeWindow's `active`, and for the same reason: two charts that each kept
// their own hover state could not be read against each other, which is the one
// thing the shared time axis exists to allow.
//
// It holds a TIME, not a pixel or a fraction. Every lane is fetched on the same
// start/end/step, so a time is the only value that means the same thing in all
// of them, and a chart whose window does not contain it simply draws nothing.
// =============================================================================

import { computed, ref } from "vue";

const hovered = ref<number | null>(null);

export function useCrosshair() {
  return {
    /** Unix seconds under the cursor, or null when nothing is hovered. */
    at: computed(() => hovered.value),
    active: computed(() => hovered.value !== null),
    setAt(t: number): void {
      hovered.value = Number.isFinite(t) ? t : null;
    },
    clear(): void {
      hovered.value = null;
    },
  };
}
