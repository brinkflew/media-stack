<script setup lang="ts">
/**
 * A coloured pill stating a fact. The Library table's STATE column and the
 * now-playing card's DIRECT / HW TRANSCODE badge are the same object.
 *
 * It is not a control and never will be - that is what ChipLink is for. Merging
 * the two would make both worse: a pill that looks clickable and is not is the
 * same class of lie as an action button that cannot act.
 */
import type { Tone } from "@/types";

withDefaults(defineProps<{ label: string; tone: Tone; size?: "sm" | "md" }>(), { size: "md" });
</script>

<template>
  <span class="pill mono" :class="[tone, size]">{{ label }}</span>
</template>

<style scoped>
.pill {
  display: inline-flex;
  align-items: center;
  border-radius: var(--r-xs);
  white-space: nowrap;
}

.md {
  padding: 2px 7px;
  font: var(--t-mono-xs);
}

.sm {
  padding: 1px 5px;
  font: var(--t-mono-xs);
  font-size: 9px;
}

/* The tint/edge pairs exist in tokens.css precisely so a coloured chip does not
   have to invent an opacity. `off` has neither, so it borrows the neutral fill. */
.ok {
  color: var(--ok);
  background: var(--ok-tint);
  border: 1px solid var(--ok-edge);
}

.warn {
  color: var(--warn);
  background: var(--warn-tint);
  border: 1px solid var(--warn-edge);
}

.fail {
  color: var(--fail-text);
  background: var(--fail-tint);
  border: 1px solid var(--fail-edge);
}

.off {
  color: var(--fg-5);
  background: var(--fill);
  border: 1px solid var(--line);
}
</style>
