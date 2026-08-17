<script setup lang="ts">
/**
 * A 4px progress bar.
 *
 * NULL AND ZERO ARE DIFFERENT FACTS AND RENDER DIFFERENTLY. A queued item really
 * is at 0%, which is a measurement; a source that does not know the progress is
 * absent, which is not. null draws the bare track and nothing else, so it can
 * never be mistaken for a fill of width zero. That is format.ts's NaN rule -
 * return the dash, never a 0 - expressed as geometry.
 *
 * `live` adds a SEPARATE OVERLAY element carrying class="sweep", never the class
 * on the fill itself. tokens.css's reduced-motion block does
 * `.sweep { display: none }` - correctly, since a parked gradient carries no
 * information - and putting that class on the fill would hide the progress along
 * with the shimmer. The colour and the width are the data; the movement is
 * emphasis, and losing it must cost nothing.
 *
 * Only genuinely live states get it. An animated bar on a stalled row would be a
 * lie about the most important thing the Library table has to say.
 */
import type { Tone } from "@/types";

const props = withDefaults(
  defineProps<{
    /** 0..1, or null when unknown. */
    ratio: number | null;
    tone: Tone;
    height?: number;
    live?: boolean;
  }>(),
  { height: 4, live: false },
);

const width = () =>
  props.ratio === null || !Number.isFinite(props.ratio)
    ? null
    : `${Math.max(0, Math.min(1, props.ratio)) * 100}%`;
</script>

<template>
  <div class="track" :style="{ height: `${height}px` }">
    <div v-if="width() !== null" class="fill" :class="tone" :style="{ width: width()! }">
      <div v-if="live" class="sweep" />
    </div>
  </div>
</template>

<style scoped>
.track {
  width: 100%;
  overflow: hidden;
  background: var(--track);
  border-radius: 999px;
}

.fill {
  position: relative;
  height: 100%;
  overflow: hidden;
  border-radius: 999px;
  transition: width 0.4s linear;
}

.ok {
  background: var(--ok);
}

.warn {
  background: var(--warn);
}

.fail {
  background: var(--fail);
}

.off {
  background: var(--off);
}

/* The moving band that says "this is still going", over whatever colour the
   state chose. Same construction as SystemPage's timeline sweep - full width,
   band painted as a background, so translateX(100%) is one whole lane - and
   tokens.css owns --sweep-band, the keyframe and the reduced-motion opt-out. */
.sweep {
  position: absolute;
  inset: 0;
  background: linear-gradient(90deg, transparent, oklch(1 0 0 / 0.35), transparent);
  background-size: var(--sweep-band) 100%;
  background-repeat: no-repeat;
  animation: sweep 2s linear infinite;
  pointer-events: none;
}
</style>
