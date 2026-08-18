<script setup lang="ts">
/**
 * The one tooltip, mounted once in App.vue.
 *
 * position: fixed and pointer-events: none, so it can never be hovered itself
 * and can never sit inside a clipping ancestor. One element on the page is
 * what makes "only one at a time" structural rather than a rule.
 *
 * HOW IT DODGES THE MetricChart TRAP. That component cannot read pointer
 * position in viewBox units because its viewBox is stretched
 * (preserveAspectRatio="none"), so it goes through getBoundingClientRect().
 * The same call is why an SVG <g> and an HTML <span> need no different code
 * here: getBoundingClientRect on an SVG child returns CSS pixels in the
 * viewport, already through the viewBox transform. Anchoring is one code path.
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { tooltipId, useTooltip } from "@/composables/useTooltip";

const tip = useTooltip();
const route = useRoute();
const box = ref<HTMLElement | null>(null);
const pos = ref<{ x: number; y: number } | null>(null);

const GAP = 8;
const EDGE = 8;

/**
 * Measured after render, not guessed. The box opens hidden, gets measured, then
 * is revealed - one invisible frame, and no flash of a tooltip in the wrong
 * corner. There is no arrow: an arrow needs a second flip axis and buys nothing
 * at this size.
 */
async function place(): Promise<void> {
  pos.value = null;
  const open = tip.current.value;
  if (!open) return;

  await nextTick();
  const el = box.value;
  if (!el) return;

  const a = open.anchor.getBoundingClientRect();
  const t = el.getBoundingClientRect();

  let x = a.left + a.width / 2 - t.width / 2;
  let y = a.top - t.height - GAP;

  if (y < EDGE) y = a.bottom + GAP;
  x = Math.min(Math.max(EDGE, x), window.innerWidth - t.width - EDGE);
  y = Math.min(y, window.innerHeight - t.height - EDGE);

  pos.value = { x, y };
}

watch(() => tip.current.value, place, { flush: "post" });

// A tooltip that survived a route change would describe a node that is gone,
// and one that survived a scroll would point at nothing. Capture phase,
// because the scroll that matters is usually on an inner panel.
function dismiss(): void {
  tip.closeAll();
}
function onKey(e: KeyboardEvent): void {
  if (e.key === "Escape") tip.closeAll();
}

onMounted(() => {
  window.addEventListener("scroll", dismiss, true);
  window.addEventListener("resize", dismiss);
  document.addEventListener("keydown", onKey);
});
onBeforeUnmount(() => {
  window.removeEventListener("scroll", dismiss, true);
  window.removeEventListener("resize", dismiss);
  document.removeEventListener("keydown", onKey);
});
watch(() => route.fullPath, dismiss);

const current = computed(() => tip.current.value);
</script>

<template>
  <div
    v-if="current"
    :id="tooltipId(current.id)"
    ref="box"
    class="tip"
    role="tooltip"
    :style="{
      left: `${pos?.x ?? 0}px`,
      top: `${pos?.y ?? 0}px`,
      visibility: pos ? 'visible' : 'hidden',
    }"
  >
    <div class="t-title">{{ current.content.title }}</div>
    <div v-for="(line, i) in current.content.lines" :key="i" class="t-line mono">{{ line }}</div>
    <div v-if="current.content.caveat" class="t-caveat mono">{{ current.content.caveat }}</div>
  </div>
</template>

<style scoped>
.tip {
  position: fixed;
  z-index: 60;
  pointer-events: none;
  max-width: 320px;
  padding: 8px 10px;
  border-radius: var(--r-sm);
  background: var(--surface-high);
  border: 1px solid var(--line-strong);
  box-shadow: var(--shadow-node);
}

.t-title {
  font: var(--t-ui-md);
  color: var(--fg);
}

.t-line {
  margin-top: 3px;
  font: var(--t-mono-sm);
  color: var(--fg-4);
}

/* Amber, and set apart by a rule rather than by colour alone. This is the line
   that says the number above it is not what it looks like. */
.t-caveat {
  margin-top: 7px;
  padding-top: 6px;
  border-top: 1px solid var(--line);
  font: var(--t-mono-sm);
  color: var(--warn);
}
</style>
