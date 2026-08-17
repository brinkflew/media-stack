<script setup lang="ts">
/**
 * A poster, or the designed absence of one.
 *
 * AN ABSENT POSTER IS THE NORMAL CASE IN TWO OF THE FOUR SLOTS, not an error. A
 * Jellyseerr request has no Jellyfin item until it lands, which is exactly the
 * state the Requests panel exists to show, and an in-flight download has not been
 * imported yet either. So the fallback is a designed tile rather than an error
 * treatment - no red, no amber, nothing that reads as a problem, because an
 * absent poster is not a status.
 *
 * A MISSING POSTER AND A FAILED FETCH RENDER IDENTICALLY, deliberately. To the
 * operator they are the same fact: there is no image. Distinguishing them would
 * put a warning colour beside every pending request.
 *
 * The fallback is drawn UNDERNEATH and always. The img sits on top at opacity 0
 * until it loads, and is removed on error - so there is never a flash of empty
 * box and no engine can ever draw its own broken-image glyph.
 */
import { computed, ref, watch } from "vue";

import { posterHeight, posterUrl } from "@/images";
import type { MediaKind } from "@/types";

const props = withDefaults(
  defineProps<{
    /** Bare Jellyfin image path, or null. */
    path: string | null;
    tag?: string | null;
    width: number;
    /** Omit to derive from width at the 2:3 poster ratio. */
    height?: number;
    title: string;
    kind?: MediaKind | null;
  }>(),
  { tag: null, height: undefined, kind: null },
);

const failed = ref(false);

const box = computed(() => ({
  width: props.width,
  height: props.height ?? Math.round((props.width * 3) / 2),
}));

const src = computed(() =>
  props.path ? posterUrl(props.path, props.tag, posterHeight(box.value.height)) : null,
);

// Reset on any src change, or a fixed table row keeps a stale failure after the
// document moves it to a different item.
watch(src, () => {
  failed.value = false;
});

/**
 * The first ASCII alphanumeric of the title, uppercased.
 *
 * Empty for a title that has none - an anime title often does - because a CJK
 * glyph at 9px in Azeret Mono renders as a fallback-font box, which looks like a
 * bug rather than a placeholder. Those get the kind mark alone. (The repository's
 * ASCII rule governs source bytes, not runtime data; this is a rendering call.)
 */
const monogram = computed(() => {
  const match = /[A-Za-z0-9]/.exec(props.title);
  return match ? match[0].toUpperCase() : "";
});

/** Suppressed below 56px: at 26x38 a mark plus a letter is mud, while the letter
 *  alone reads as intentional. */
const showMark = computed(() => props.width >= 56 || !monogram.value);
</script>

<template>
  <div class="tile" :style="{ width: `${box.width}px`, height: `${box.height}px` }">
    <div class="fallback">
      <span v-if="monogram" class="mono glyph" :style="{ fontSize: `${Math.max(9, box.width * 0.34)}px` }">
        {{ monogram }}
      </span>
      <!-- Inline SVG rather than a unicode glyph: bin/lint-repo.sh fails the
           whole repository on one byte above 0x7F. -->
      <svg
        v-if="showMark"
        class="mark"
        :width="Math.round(box.width * 0.36)"
        :height="Math.round(box.width * 0.36)"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
        aria-hidden="true"
      >
        <template v-if="kind === 'series'">
          <rect x="2.5" y="6.5" width="14" height="11" rx="1.5" />
          <path d="M6 4.5h14v11" />
        </template>
        <template v-else>
          <rect x="4.5" y="3.5" width="15" height="17" rx="1.5" />
          <path d="M8 3.5v17M16 3.5v17" opacity="0.55" />
        </template>
      </svg>
    </div>

    <img
      v-if="src && !failed"
      class="img"
      :src="src"
      :width="box.width"
      :height="box.height"
      :alt="title"
      loading="lazy"
      decoding="async"
      @error="failed = true"
    />
  </div>
</template>

<style scoped>
.tile {
  position: relative;
  flex: none;
  overflow: hidden;
  border-radius: var(--r-xs);
  /* Down the surface scale is how tokens.css says "inset". Same box as a real
     poster, so nothing shifts when one arrives. */
  background: var(--surface-sunken);
  border: 1px solid var(--line-faint);
}

.fallback {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 4px;
  /* Never teal, never amber: an absent poster is not a status. */
  color: var(--fg-dim);
}

.glyph {
  font-weight: 500;
  line-height: 1;
}

.mark {
  opacity: 0.35;
}

.img {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  /* Fades in over the fallback, so there is no empty frame between them. */
  animation: poster-in 0.18s ease-out forwards;
}

@keyframes poster-in {
  from {
    opacity: 0;
  }
  to {
    opacity: 1;
  }
}

@media (prefers-reduced-motion: reduce) {
  .img {
    animation: none;
    opacity: 1;
  }
}
</style>
