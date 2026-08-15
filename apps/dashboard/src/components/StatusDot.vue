<script setup lang="ts">
/**
 * The three-colour status vocabulary, as one dot.
 *
 * `off` is grey and is the default, which matters: an unmeasured thing must
 * never render green. That is the same argument bin/verify-host.sh makes for
 * emitting a `note` rather than a `pass` when a check could not run.
 */
import { computed } from "vue";

const props = withDefaults(
  defineProps<{
    tone?: "ok" | "warn" | "fail" | "off";
    /** Breathing. Reserved for something genuinely in progress or failing. */
    live?: boolean;
    /** An LED rather than a dot: adds the bloom used in the pod rack. */
    glow?: boolean;
    size?: number;
  }>(),
  { tone: "off", live: false, glow: false, size: 5 },
);

const colour = computed(() => `var(--${props.tone})`);
</script>

<template>
  <span
    class="dot"
    :class="{ live, glow }"
    :style="{
      '--dot-colour': colour,
      width: `${size}px`,
      height: `${size}px`,
    }"
  />
</template>

<style scoped>
.dot {
  display: inline-block;
  flex: none;
  border-radius: 999px;
  background: var(--dot-colour);
}

.glow {
  box-shadow: 0 0 7px var(--dot-colour);
}

.live {
  animation: pulse 1.6s ease-in-out infinite;
}
</style>
